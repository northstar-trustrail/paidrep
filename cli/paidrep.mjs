#!/usr/bin/env node
// paidrep — CLI for ERC-8183 jobs on Arc that write escrow-backed ERC-8004 reputation.
// Usage: node paidrep.mjs <command> [...args]   (PRIVATE_KEY env var for write commands)
import { createPublicClient, createWalletClient, http, parseAbi, parseUnits, formatUnits, keccak256, toHex, decodeEventLog } from "viem";
import { arc } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const D = JSON.parse(readFileSync(process.env.DEPLOYMENT || join(here, "..", "deployments", "arc-mainnet.json"), "utf8"));
const RPC = process.env.ARC_RPC || "https://rpc.mainnet.arc.io";
const pub = createPublicClient({ chain: arc, transport: http(RPC) });
const wallet = () => {
  if (!process.env.PRIVATE_KEY) throw new Error("set PRIVATE_KEY");
  return createWalletClient({ chain: arc, transport: http(RPC), account: privateKeyToAccount(process.env.PRIVATE_KEY.startsWith("0x") ? process.env.PRIVATE_KEY : "0x" + process.env.PRIVATE_KEY) });
};

const escrowAbi = parseAbi([
  "function createJob(address provider,address evaluator,uint48 expiredAt,string description,address hook,uint256 providerAgentId) returns (uint256)",
  "function setBudget(uint256 jobId,address token,uint256 amount,bytes optParams)",
  "function fund(uint256 jobId,address expectedToken,uint256 expectedBudget,bytes optParams)",
  "function submit(uint256 jobId,bytes32 deliverable,bytes optParams)",
  "function complete(uint256 jobId,bytes32 reason,bytes optParams)",
  "function reject(uint256 jobId,bytes32 reason,bytes optParams)",
  "function claimRefund(uint256 jobId)",
  "function jobCounter() view returns (uint256)",
  "function getJob(uint256 jobId) view returns ((address client,uint8 status,address provider,uint48 expiredAt,address evaluator,uint48 submittedAt,uint256 budget,address hook,address paymentToken,uint256 providerAgentId,string description,uint256 settledAmount,address payoutReceiver))",
  "event JobCreated(uint256 indexed jobId,address indexed client,address indexed provider,address evaluator,uint48 expiredAt,address hook)",
]);
const erc20 = parseAbi(["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)"]);
const identityAbi = parseAbi([
  "function register(string agentURI) returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
  "function tokenURI(uint256) view returns (string)",
  "event Registered(uint256 indexed agentId, string agentURI, address indexed owner)",
]);
const repAbi = parseAbi([
  "function getSummary(uint256 agentId,address[] clientAddresses,string tag1,string tag2) view returns (uint64 count,int128 summaryValue,uint8 summaryValueDecimals)",
]);
const STATUS = ["Open", "Funded", "Submitted", "Completed", "Rejected", "Expired"];
const h32 = (s) => (s.startsWith("0x") && s.length === 66 ? s : keccak256(toHex(s)));

async function send(fn, address, abi, args) {
  const w = wallet();
  const hash = await w.writeContract({ address, abi, functionName: fn, args });
  const r = await pub.waitForTransactionReceipt({ hash });
  console.log(`${fn}: ${hash} status=${r.status} block=${r.blockNumber} gasUsed=${r.gasUsed}`);
  if (r.status !== "success") process.exit(1);
  return r;
}

async function reputation(agentId) {
  const q = (tag2) => pub.readContract({ address: D.reputationRegistry, abi: repAbi, functionName: "getSummary", args: [BigInt(agentId), [D.hook], "erc8183", tag2] });
  const [[cc], [pc, pavg, pdec], [rc]] = await Promise.all([q("completed"), q("paid"), q("rejected")]);
  const total = pc * pavg; // summary is an average; count*avg = total paid
  return {
    agentId: String(agentId),
    owner: await pub.readContract({ address: D.identityRegistry, abi: identityAbi, functionName: "ownerOf", args: [BigInt(agentId)] }).catch(() => null),
    escrowBackedFeedbackFrom: D.hook,
    completedJobs: Number(cc),
    rejectedAfterSubmit: Number(rc),
    successRate: cc + rc > 0n ? Number(cc) / Number(cc + rc) : null,
    paidVolumeUSDC: formatUnits(total < 0n ? 0n : BigInt(total), pdec || 6),
  };
}

const [cmd, ...a] = process.argv.slice(2);
const json = (o) => console.log(JSON.stringify(o, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
switch (cmd) {
  case "info":
    json({ ...D, jobCounter: await pub.readContract({ address: D.escrow, abi: escrowAbi, functionName: "jobCounter" }) });
    break;
  case "job": {
    const j = await pub.readContract({ address: D.escrow, abi: escrowAbi, functionName: "getJob", args: [BigInt(a[0])] });
    json({ ...j, status: STATUS[j.status], budgetUSDC: formatUnits(j.budget, 6) });
    break;
  }
  case "rep":
    json(await reputation(a[0]));
    break;
  case "register": { // register <agentURI>
    const r = await send("register", D.identityRegistry, identityAbi, [a[0]]);
    for (const l of r.logs) { try { const e = decodeEventLog({ abi: identityAbi, ...l }); if (e.eventName === "Registered") console.log("agentId", e.args.agentId.toString()); } catch {} }
    break;
  }
  case "create": { // create <provider> <evaluator> <hours> <description> [agentId]
    const exp = BigInt(Math.floor(Date.now() / 1000) + Number(a[2]) * 3600);
    const r = await send("createJob", D.escrow, escrowAbi, [a[0], a[1], exp, a[3], D.hook, BigInt(a[4] || 0)]);
    for (const l of r.logs) { try { const e = decodeEventLog({ abi: escrowAbi, ...l }); if (e.eventName === "JobCreated") console.log("jobId", e.args.jobId.toString()); } catch {} }
    break;
  }
  case "budget": // budget <jobId> <usdc>
    await send("setBudget", D.escrow, escrowAbi, [BigInt(a[0]), D.usdc, parseUnits(a[1], 6), "0x"]);
    break;
  case "fund": { // fund <jobId>
    const j = await pub.readContract({ address: D.escrow, abi: escrowAbi, functionName: "getJob", args: [BigInt(a[0])] });
    await send("approve", j.paymentToken, erc20, [D.escrow, j.budget]);
    await send("fund", D.escrow, escrowAbi, [BigInt(a[0]), j.paymentToken, j.budget, "0x"]);
    break;
  }
  case "submit": // submit <jobId> <deliverable text|bytes32>
    await send("submit", D.escrow, escrowAbi, [BigInt(a[0]), h32(a[1]), "0x"]);
    break;
  case "complete": // complete <jobId> <reason>
    await send("complete", D.escrow, escrowAbi, [BigInt(a[0]), h32(a[1] || "ok"), "0x"]);
    break;
  case "reject":
    await send("reject", D.escrow, escrowAbi, [BigInt(a[0]), h32(a[1] || "rejected"), "0x"]);
    break;
  case "refund":
    await send("claimRefund", D.escrow, escrowAbi, [BigInt(a[0])]);
    break;
  default:
    console.log(`paidrep — ERC-8183 jobs on Arc with escrow-backed ERC-8004 reputation
commands:
  info                                   deployment + job counter
  job <id>                               show a job
  rep <agentId>                          escrow-backed reputation summary
  register <agentURI>                    register an ERC-8004 agent identity (PRIVATE_KEY)
  create <provider> <evaluator> <hours> <description> [agentId]
  budget <jobId> <usdc>                  provider sets price
  fund <jobId>                           client approves + funds escrow
  submit <jobId> <deliverable>           provider submits (text is keccak-hashed)
  complete|reject <jobId> [reason]       evaluator settles; hook writes reputation
  refund <jobId>                         anyone, after expiry`);
}
