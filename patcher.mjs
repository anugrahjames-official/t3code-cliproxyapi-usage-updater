import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { promises as fs } from "node:fs";
import path from "node:path";
import { createPackageWithOptions, extractAll, extractFile, listPackage } from "@electron/asar";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PATCH_MARKER = "T3_GROK_HUB_USAGE_PATCH_V1";
const ANTIGRAVITY_PATCH_MARKER = "T3_ANTIGRAVITY_HUB_USAGE_PATCH_V1";
const ANTIGRAVITY_MODEL_FILTER_MARKER = "T3_ANTIGRAVITY_HUB_MODEL_ALLOWLIST_V1";
const MAIN_BUNDLE_RE = /^apps\/server\/dist\/server-[A-Za-z0-9_-]+\.mjs$/i;

function normalizeArchivePath(value) {
  return value.replace(/^[\\/]+/, "").replace(/[\\/]+/g, "/");
}

function countText(value, needle) {
  if (!needle) return 0;
  return value.split(needle).length - 1;
}

function getBundlePath(archive) {
  const matches = listPackage(archive)
    .map(normalizeArchivePath)
    .filter((name) => MAIN_BUNDLE_RE.test(name));
  if (matches.length !== 1) {
    throw new Error("Expected one apps/server/dist/server-*.mjs bundle; found " + matches.length + ".");
  }
  return matches[0];
}

function extractBundle(archive, relativePath) {
  const archivePath = relativePath.split("/").join(path.sep);
  return extractFile(archive, archivePath).toString("utf8");
}

function getUsageAdapter(source) {
  const beginNeedle = "// src/usage/cliproxyApi.ts";
  const endNeedle = "// src/usage/UsageLimitSources.ts";
  if (countText(source, beginNeedle) !== 1 || countText(source, endNeedle) !== 1) {
    throw new Error("The CLIProxy usage adapter boundaries are missing or ambiguous.");
  }
  const begin = source.indexOf(beginNeedle);
  const end = source.indexOf(endNeedle, begin + beginNeedle.length);
  if (end <= begin) throw new Error("The CLIProxy usage adapter boundary order is unexpected.");
  return { begin, end, text: source.slice(begin, end) };
}

function scanAdapter(adapter) {
  const grokPresent = adapter.includes(PATCH_MARKER) || (
    adapter.includes("GrokUsage") ||
    adapter.includes("https://cli-chat-proxy.grok.com/v1/billing") ||
    /account\.provider\s*===\s*"xai"/.test(adapter)
  );
  const antigravityPresent = adapter.includes(ANTIGRAVITY_PATCH_MARKER);
  if (grokPresent && antigravityPresent) {
    return { status: "already-present", reason: "Grok and Antigravity usage logic is present." };
  }
  if (grokPresent) {
    return { status: "needs-antigravity", reason: "Grok usage logic is present; Antigravity pooled usage is not." };
  }
  return { status: "unpatched", reason: "No Grok usage branch was found." };
}

function readPackageState(archive) {
  const rows = listPackage(archive, { isPack: true });
  const paths = [];
  const unpacked = [];
  const links = [];
  for (const row of rows) {
    const match = row.match(/^\s*(pack|unpack|link)\s*:\s*(.*)$/i);
    if (match) {
      const kind = match[1].toLowerCase();
      const name = normalizeArchivePath(match[2]);
      paths.push(name);
      if (kind === "unpack") unpacked.push(name);
      if (kind === "link") links.push(name);
    } else {
      paths.push(normalizeArchivePath(row));
    }
  }
  return { paths, unpacked, links };
}

function makeUnpackPattern(unpackedPaths) {
  const names = [...new Set(unpackedPaths.map((name) => name.slice(name.lastIndexOf("/") + 1)))];
  if (names.some((name) => /[{},*?\[\]!]/.test(name))) {
    throw new Error("An unpacked filename uses glob characters; refusing to repack it ambiguously.");
  }
  if (names.length === 0) return undefined;
  return names.length === 1 ? names[0] : "{" + names.join(",") + "}";
}

async function hashFile(filePath) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) hash.update(chunk);
  return hash.digest("hex");
}

async function fileMap(root) {
  const result = new Map();
  try {
    await fs.access(root);
  } catch {
    return result;
  }
  async function walk(current, relative) {
    const entries = await fs.readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      const child = path.join(current, entry.name);
      const rel = relative ? relative + "/" + entry.name : entry.name;
      if (entry.isSymbolicLink()) throw new Error("Symbolic links in the unpacked tree are not supported by this updater.");
      if (entry.isDirectory()) await walk(child, rel);
      else if (entry.isFile()) result.set(rel.toLowerCase(), await hashFile(child));
      else throw new Error("Unexpected file type in the unpacked tree: " + rel);
    }
  }
  await walk(root, "");
  return result;
}

function compareSets(left, right, label) {
  if (left.length !== right.length) {
    throw new Error(label + " entry count changed (" + left.length + " -> " + right.length + ").");
  }
  const a = new Set(left.map((value) => value.toLowerCase()));
  const b = new Set(right.map((value) => value.toLowerCase()));
  if (a.size !== b.size || [...a].some((value) => !b.has(value))) {
    throw new Error(label + " paths changed while repacking.");
  }
}

async function patchAdapter(adapter) {
  let output = adapter;
  const grokSchemaPath = path.join(SCRIPT_DIR, "fragments", "grok-usage-schema.js.txt");
  const grokBranchPath = path.join(SCRIPT_DIR, "fragments", "grok-account-branch.js.txt");
  const antigravitySchemaPath = path.join(SCRIPT_DIR, "fragments", "antigravity-usage-schema.js.txt");
  const antigravityBranchPath = path.join(SCRIPT_DIR, "fragments", "antigravity-account-branch.js.txt");
  const [grokSchemaText, grokBranchText, antigravitySchemaText, antigravityBranchText] = await Promise.all([
    fs.readFile(grokSchemaPath, "utf8"),
    fs.readFile(grokBranchPath, "utf8"),
    fs.readFile(antigravitySchemaPath, "utf8"),
    fs.readFile(antigravityBranchPath, "utf8")
  ]);

  const grokPresent = output.includes(PATCH_MARKER) || output.includes("GrokUsage") ||
    output.includes("https://cli-chat-proxy.grok.com/v1/billing");
  if (!grokPresent) {
    const creditListAnchor = "const CreditList = Struct({";
    if (countText(output, creditListAnchor) !== 1) throw new Error("CreditList schema anchor is missing or ambiguous.");
    output = output.replace(creditListAnchor, grokSchemaText.trimEnd() + "\n" + creditListAnchor);

    const decoderAnchor = "const decodeCodexUsage = decodeUnknownEffect(fromJsonString(CodexUsage));";
    if (countText(output, decoderAnchor) !== 1) throw new Error("Codex usage decoder anchor is missing or ambiguous.");
    output = output.replace(decoderAnchor, decoderAnchor + "\nconst decodeGrokUsage = decodeEffect(fromJsonString(GrokUsage));");

    const apiCallStart = output.indexOf('const apiCall = fn("CliproxyApi.apiCall")');
    const creditsStart = output.indexOf('const credits = fn("CliproxyApi.credits")', apiCallStart);
    if (apiCallStart < 0 || creditsStart <= apiCallStart) throw new Error("CLIProxy API call block boundaries are missing or ambiguous.");
    let apiCall = output.slice(apiCallStart, creditsStart);
    const claudeHeader = ["\t\t} : {", '\t\t\tAuthorization: "Bearer $TOKEN$",', '\t\t\t"anthropic-beta": "oauth-2025-04-20",'].join("\n");
    if (countText(apiCall, claudeHeader) !== 1) throw new Error("CLIProxy Claude authorization header anchor is missing or ambiguous.");
    const xaiHeader = ['\t\t} : account.provider === "xai" ? {', '\t\t\tAuthorization: "Bearer $TOKEN$"', "\t\t} : {", '\t\t\tAuthorization: "Bearer $TOKEN$",', '\t\t\t"anthropic-beta": "oauth-2025-04-20",'].join("\n");
    apiCall = apiCall.replace(claudeHeader, xaiHeader);
    output = output.slice(0, apiCallStart) + apiCall + output.slice(creditsStart);

    const driverAnchor = 'ProviderDriverKind.make(account.provider === "codex" ? "codex" : "claudeAgent")';
    if (countText(output, driverAnchor) !== 1) throw new Error("CLIProxy account driver mapping anchor is missing or ambiguous.");
    output = output.replace(driverAnchor, 'ProviderDriverKind.make(account.provider === "codex" ? "codex" : account.provider === "xai" ? "grok" : "claudeAgent")');

    const readAccountStart = output.indexOf('const readAccount = fn("CliproxyApi.readAccount")');
    const claudeBranchAnchor = 'if (account.provider === "claude") {';
    const claudeBranchIndex = output.indexOf(claudeBranchAnchor, readAccountStart);
    if (readAccountStart < 0 || claudeBranchIndex <= readAccountStart || output.indexOf(claudeBranchAnchor, claudeBranchIndex + claudeBranchAnchor.length) !== -1) throw new Error("CLIProxy readAccount branch anchor is missing or ambiguous.");
    output = output.slice(0, claudeBranchIndex) + grokBranchText.trimEnd() + "\n" + output.slice(claudeBranchIndex);

    const providersAnchor = 'account.provider === "codex" || account.provider === "claude"';
    if (countText(output, providersAnchor) !== 1) throw new Error("CLIProxy account provider filter anchor is missing or ambiguous.");
    output = output.replace(providersAnchor, 'account.provider === "codex" || account.provider === "claude" || account.provider === "xai"');
  }

  if (!output.includes(ANTIGRAVITY_PATCH_MARKER)) {
    const projectIdAnchor = 'disabled: optional$6(Boolean$1),\n\tid_token: optional$6(Struct({';
    if (countText(output, projectIdAnchor) === 1) {
      output = output.replace(projectIdAnchor, 'disabled: optional$6(Boolean$1),\n\tproject_id: optional$6(String$1),\n\tid_token: optional$6(Struct({');
    } else if (!/project_id:\s*optional\$6\(String\$1\)/.test(output)) {
      throw new Error("CLIProxy auth-file project_id schema anchor is missing or ambiguous.");
    }

    const creditListAnchor = "const CreditList = Struct({";
    if (countText(output, creditListAnchor) !== 1) throw new Error("CreditList schema anchor is missing or ambiguous.");
    output = output.replace(creditListAnchor, antigravitySchemaText.trimEnd() + "\n" + creditListAnchor);

    const grokDecoderAnchor = 'const decodeGrokUsage = decodeEffect(fromJsonString(GrokUsage));';
    if (countText(output, grokDecoderAnchor) !== 1) throw new Error("Grok usage decoder anchor is missing or ambiguous.");
    output = output.replace(grokDecoderAnchor, grokDecoderAnchor + "\nconst decodeAntigravitySummary = decodeEffect(fromJsonString(AntigravitySummary));\nconst decodeAntigravityModels = decodeEffect(fromJsonString(AntigravityModels));");

    const apiCallStart = output.indexOf('const apiCall = fn("CliproxyApi.apiCall")');
    const creditsStart = output.indexOf('const credits = fn("CliproxyApi.credits")', apiCallStart);
    const apiCall = output.slice(apiCallStart, creditsStart);
    const xaiHeader = ['\t\t} : account.provider === "xai" ? {', '\t\t\tAuthorization: "Bearer $TOKEN$"', "\t\t} : {", '\t\t\tAuthorization: "Bearer $TOKEN$",', '\t\t\t"anthropic-beta": "oauth-2025-04-20",'].join("\n");
    if (apiCallStart < 0 || creditsStart <= apiCallStart || countText(apiCall, xaiHeader) !== 1) throw new Error("CLIProxy xAI authorization header anchor is missing or ambiguous.");
    const antigravityHeader = ['\t\t} : account.provider === "xai" ? {', '\t\t\tAuthorization: "Bearer $TOKEN$"', '\t\t} : account.provider === "antigravity" ? {', '\t\t\tAuthorization: "Bearer $TOKEN$",', '\t\t\t"Content-Type": "application/json",', '\t\t\t"User-Agent": "antigravity/hub/2.24.0 (aidev_client; os_type=windows; arch=x64; cl=963137146)"', "\t\t} : {", '\t\t\tAuthorization: "Bearer $TOKEN$",', '\t\t\t"anthropic-beta": "oauth-2025-04-20",'].join("\n");
    const updatedApiCall = apiCall.replace(xaiHeader, antigravityHeader);
    output = output.slice(0, apiCallStart) + updatedApiCall + output.slice(creditsStart);

    const driverAnchor = 'ProviderDriverKind.make(account.provider === "codex" ? "codex" : account.provider === "xai" ? "grok" : "claudeAgent")';
    if (countText(output, driverAnchor) !== 1) throw new Error("Grok-aware account driver mapping anchor is missing or ambiguous.");
    output = output.replace(driverAnchor, 'ProviderDriverKind.make(account.provider === "codex" ? "codex" : account.provider === "xai" ? "grok" : account.provider === "antigravity" ? "antigravity" : "claudeAgent")');

    const readAccountStart = output.indexOf('const readAccount = fn("CliproxyApi.readAccount")');
    const claudeBranchAnchor = 'if (account.provider === "claude") {';
    const claudeBranchIndex = output.indexOf(claudeBranchAnchor, readAccountStart);
    if (readAccountStart < 0 || claudeBranchIndex <= readAccountStart || output.indexOf(claudeBranchAnchor, claudeBranchIndex + claudeBranchAnchor.length) !== -1) throw new Error("CLIProxy Claude account branch anchor is missing or ambiguous.");
    output = output.slice(0, claudeBranchIndex) + antigravityBranchText.trimEnd() + "\n" + output.slice(claudeBranchIndex);

    const providersAnchor = 'account.provider === "codex" || account.provider === "claude" || account.provider === "xai"';
    if (countText(output, providersAnchor) !== 1) throw new Error("CLIProxy provider filter anchor is missing or ambiguous.");
    output = output.replace(providersAnchor, providersAnchor + ' || account.provider === "antigravity"');
  }

  if (countText(output, PATCH_MARKER) !== 1 ||
      countText(output, ANTIGRAVITY_PATCH_MARKER) !== 2 ||
      countText(output, "const decodeGrokUsage =") !== 1 ||
      countText(output, "const decodeAntigravitySummary =") !== 1 ||
      countText(output, "v1internal:retrieveUserQuotaSummary") !== 1 ||
      countText(output, "https://cli-chat-proxy.grok.com/v1/billing?format=credits") !== 1 ||
      !/account\.provider\s*===\s*"antigravity"/.test(output)) {
    throw new Error("Patched CLIProxy adapter did not pass its Grok and Antigravity structural checks.");
  }
  return output;
}

function patchAntigravityHubModelAllowlist(source) {
  const markerCount = countText(source, ANTIGRAVITY_MODEL_FILTER_MARKER);
  if (markerCount === 1) return source;
  if (markerCount !== 0) throw new Error("Antigravity Hub model allowlist marker is duplicated.");

  const anchor = 'const visible = input.provider.models.filter((model) => model.isCustom || !input.preferences?.hiddenModels.includes(model.slug)).toSorted((a, b) => (rank.get(a.slug) ?? rank.size) - (rank.get(b.slug) ?? rank.size));';
  if (countText(source, anchor) !== 1) {
    throw new Error("Provider model visibility filter anchor is missing or ambiguous; refusing to patch this T3 build.");
  }

  const replacement = [
    "/* " + ANTIGRAVITY_MODEL_FILTER_MARKER + " */",
    'const antigravityHubAllowlist = input.provider.instanceId === "antigravity-hub" ? input.preferences?.modelOrder ?? [] : null;',
    'const visible = input.provider.models.filter((model) => antigravityHubAllowlist !== null ? antigravityHubAllowlist.includes(model.slug) : model.isCustom || !input.preferences?.hiddenModels.includes(model.slug)).toSorted((a, b) => (rank.get(a.slug) ?? rank.size) - (rank.get(b.slug) ?? rank.size));'
  ].join("\n\t");
  return source.replace(anchor, replacement);
}

async function inspectArchive(archive) {
  const relativePath = getBundlePath(archive);
  const source = extractBundle(archive, relativePath);
  const adapter = getUsageAdapter(source);
  const adapterStatus = scanAdapter(adapter.text);
  const modelFilterPresent = countText(source, ANTIGRAVITY_MODEL_FILTER_MARKER) === 1;
  const status = adapterStatus.status === "already-present" && !modelFilterPresent
    ? { status: "needs-antigravity-model-allowlist", reason: "Grok and Antigravity pooled usage is present; the Antigravity (Hub) picker still includes other provider and Claude models." }
    : adapterStatus;
  return {
    ...status,
    antigravityModelAllowlistPresent: modelFilterPresent,
    modulePath: relativePath,
    moduleSha256: createHash("sha256").update(source).digest("hex"),
    archiveSha256: await hashFile(archive)
  };
}

async function buildArchive(archive, workRoot) {
  const initialHash = await hashFile(archive);
  const initialState = readPackageState(archive);
  if (initialState.links.length > 0) {
    throw new Error("Archive contains symbolic links; refusing a lossy Windows repack.");
  }
  const relativePath = getBundlePath(archive);
  const originalText = extractBundle(archive, relativePath);
  const adapterInfo = getUsageAdapter(originalText);
  const currentStatus = scanAdapter(adapterInfo.text);
  const modelFilterPresent = countText(originalText, ANTIGRAVITY_MODEL_FILTER_MARKER) === 1;
  if (currentStatus.status === "already-present" && modelFilterPresent) {
    return {
      status: "already-present",
      reason: "Grok and Antigravity usage plus the Antigravity Hub model allowlist are already present.",
      modulePath: relativePath,
      archiveSha256: initialHash
    };
  }
  if (countText(originalText, ANTIGRAVITY_MODEL_FILTER_MARKER) > 1) {
    throw new Error("Antigravity Hub model allowlist marker is duplicated; refusing to rebuild this archive.");
  }

  const patchedAdapter = await patchAdapter(adapterInfo.text);
  const adapterPatchedText =
    originalText.slice(0, adapterInfo.begin) +
    patchedAdapter +
    originalText.slice(adapterInfo.end);
  const patchedText = patchAntigravityHubModelAllowlist(adapterPatchedText);

  await fs.rm(workRoot, { recursive: true, force: true });
  const sourceRoot = path.join(workRoot, "source");
  const outputArchive = path.join(workRoot, "server.asar.patched");
  await fs.mkdir(sourceRoot, { recursive: true });
  await extractAll(archive, sourceRoot);

  const modulePath = path.join(sourceRoot, ...relativePath.split("/"));
  const extractedText = await fs.readFile(modulePath, "utf8");
  if (extractedText !== originalText) {
    throw new Error("The archive changed between inspection and extraction.");
  }
  await fs.writeFile(modulePath, patchedText, "utf8");

  const pattern = makeUnpackPattern(initialState.unpacked);
  await createPackageWithOptions(sourceRoot, outputArchive, { dot: true, unpack: pattern });

  if ((await hashFile(archive)) !== initialHash) {
    throw new Error("Installed server.asar changed while the patch was being built.");
  }

  const outputState = readPackageState(outputArchive);
  if (outputState.links.length > 0) {
    throw new Error("Repacked archive unexpectedly contains symbolic links.");
  }
  compareSets(initialState.paths, outputState.paths, "Archive");
  compareSets(initialState.unpacked, outputState.unpacked, "Unpacked");
  const beforeUnpacked = await fileMap(archive + ".unpacked");
  const afterUnpacked = await fileMap(outputArchive + ".unpacked");
  if (beforeUnpacked.size !== afterUnpacked.size ||
      [...beforeUnpacked].some(([name, hash]) => afterUnpacked.get(name) !== hash)) {
    throw new Error("Repacking changed the server.asar.unpacked files; refusing to install.");
  }

  const verifiedPath = getBundlePath(outputArchive);
  const verifiedText = extractBundle(outputArchive, verifiedPath);
  const verifiedAdapter = getUsageAdapter(verifiedText).text;
  if (verifiedPath !== relativePath ||
      countText(verifiedAdapter, PATCH_MARKER) !== 1 ||
      scanAdapter(verifiedAdapter).status !== "already-present" ||
      countText(verifiedText, ANTIGRAVITY_MODEL_FILTER_MARKER) !== 1) {
    throw new Error("Repacked archive did not preserve the Grok/Antigravity usage and picker patches.");
  }

  return {
    status: "prepared",
    sourceHash: initialHash,
    patchedHash: await hashFile(outputArchive),
    modulePath: relativePath,
    outputArchive
  };
}

async function main() {
  const [command, archiveArg, workArg] = process.argv.slice(2);
  if (!command || !archiveArg) throw new Error("Usage: patcher.mjs inspect <server.asar> | build <server.asar> <work-dir>");
  const archive = path.resolve(archiveArg);
  if (command === "inspect") {
    console.log(JSON.stringify(await inspectArchive(archive)));
    return;
  }
  if (command === "build") {
    if (!workArg) throw new Error("build requires a work directory.");
    console.log(JSON.stringify(await buildArchive(archive, path.resolve(workArg))));
    return;
  }
  throw new Error("Unknown command: " + command);
}

main().catch((error) => {
  console.error("GROK_UPDATER_ERROR: " + (error?.stack || error?.message || String(error)));
  process.exitCode = 1;
});
