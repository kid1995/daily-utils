#!/usr/bin/env node
/**
 * jenkins_api.js
 * --------------
 * Query the Jenkins REST API from the GCloud Workstation.
 *
 * WHY NODE.JS AND NOT CURL?
 * --------------------------
 * curl hangs when authenticating against Jenkins from the workstation because
 * Jenkins triggers an LDAP lookup to verify credentials, and the LDAP server
 * is on a subnet not routable from the workstation. Node.js uses a different
 * TLS stack and does NOT trigger this hang.
 *
 * The Jenkins Workbench VS Code extension also uses Node.js — which is why
 * that extension works fine from the same workstation.
 *
 * KEY TRICK:
 *   NODE_TLS_REJECT_UNAUTHORIZED=0 must be set as a SHELL env var BEFORE
 *   node starts. Setting process.env inside the script does NOT work for
 *   TLS connections that are already being established.
 *
 * Usage:
 *   source ~/.credentials
 *   NODE_TLS_REJECT_UNAUTHORIZED=0 node jenkins_api.js
 *
 * Prerequisites:
 *   JENKINS_PERSONAL_TOKEN must be set (from ~/.credentials)
 */

"use strict";

const https = require("https");

// ─── Config ──────────────────────────────────────────────────────────────────

const JENKINS_HOST = "sda-jenkins.system.local";
const JENKINS_PORT = 443;
const JENKINS_USER = "u167653";

// Token comes from environment — never hardcode it
const JENKINS_TOKEN = process.env.JENKINS_PERSONAL_TOKEN;
if (!JENKINS_TOKEN) {
  console.error("❌ JENKINS_PERSONAL_TOKEN is not set. Run: source ~/.credentials");
  process.exit(1);
}

// Basic auth header: base64(username:token)
const AUTH_HEADER = "Basic " + Buffer.from(`${JENKINS_USER}:${JENKINS_TOKEN}`).toString("base64");

// ─── HTTP helper ─────────────────────────────────────────────────────────────

/**
 * Make an authenticated GET request to the Jenkins API.
 *
 * @param {string} path - URL path, e.g. "/api/json?tree=jobs[name,color]"
 * @returns {Promise<{status: number, body: string}>}
 */
function jenkinsGet(path) {
  return new Promise((resolve, reject) => {
    const opts = {
      hostname: JENKINS_HOST,
      port: JENKINS_PORT,
      path,
      method: "GET",
      headers: {
        Authorization: AUTH_HEADER,
        // Jenkins returns JSON when this header is present
        Accept: "application/json",
      },
      timeout: 10_000,
    };

    const req = https.request(opts, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });

    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("Request timed out — LDAP lookup may have hung"));
    });

    req.end();
  });
}

/**
 * POST to Jenkins (e.g. to trigger a build).
 * Jenkins requires a CSRF crumb for all POST requests.
 *
 * @param {string} path - URL path to POST to
 * @param {string} crumb - CSRF crumb value
 * @param {string} crumbField - CSRF crumb request field name
 * @returns {Promise<{status: number}>}
 */
function jenkinsPost(path, crumb, crumbField) {
  return new Promise((resolve, reject) => {
    const opts = {
      hostname: JENKINS_HOST,
      port: JENKINS_PORT,
      path,
      method: "POST",
      headers: {
        Authorization: AUTH_HEADER,
        [crumbField]: crumb,        // CSRF crumb header
        "Content-Length": 0,        // POST with no body
      },
      timeout: 10_000,
    };

    const req = https.request(opts, (res) => {
      resolve({ status: res.statusCode });
    });

    req.on("error", reject);
    req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
    req.end();
  });
}

// ─── High-level helpers ───────────────────────────────────────────────────────

/**
 * List all jobs in a folder with their build status.
 *
 * @param {string} folderPath - e.g. "/job/ELPA" or "" for root
 */
async function listJobs(folderPath = "") {
  const { status, body } = await jenkinsGet(
    `${folderPath}/api/json?tree=jobs[name,color,lastBuild[result,number,timestamp]]`
  );
  if (status !== 200) {
    console.error(`HTTP ${status}`);
    return;
  }
  const { jobs = [] } = JSON.parse(body);
  console.log(`${jobs.length} jobs in ${folderPath || "/"}`);
  for (const job of jobs) {
    // color: "blue" = success, "red" = failed, "blue_anime"/"red_anime" = running
    const icon =
      job.color === "blue" ? "✅" :
      job.color?.includes("red") ? "❌" :
      job.color?.includes("anime") ? "🔄" : "⚪";

    const lastBuild = job.lastBuild
      ? `#${job.lastBuild.number} ${job.lastBuild.result ?? "RUNNING"}`
      : "never";

    console.log(`  ${icon}  ${job.name.padEnd(45)} ${lastBuild}`);
  }
}

/**
 * Print the last N lines of a build's console log.
 *
 * @param {string} jobPath - e.g. "/job/ELPA/job/application-service"
 * @param {number} lines   - how many lines from the end to show
 */
async function getLog(jobPath, lines = 80) {
  const { status, body } = await jenkinsGet(`${jobPath}/lastBuild/consoleText`);
  if (status !== 200) { console.error(`HTTP ${status}`); return; }
  const allLines = body.split("\n");
  console.log(`--- Last ${lines} lines ---`);
  console.log(allLines.slice(-lines).join("\n"));
}

/**
 * Trigger a build (fetches CSRF crumb first, then POSTs).
 *
 * @param {string} jobPath - e.g. "/job/ELPA/job/application-service"
 */
async function triggerBuild(jobPath) {
  // Step 1: Get CSRF crumb — Jenkins requires this for all POST requests
  const { status: cs, body: cb } = await jenkinsGet("/crumbIssuer/api/json");
  if (cs !== 200) { console.error(`Could not fetch crumb: HTTP ${cs}`); return; }

  const { crumbRequestField, crumb } = JSON.parse(cb);

  // Step 2: POST to trigger the build
  const { status } = await jenkinsPost(`${jobPath}/build`, crumb, crumbRequestField);
  if (status === 201) {
    console.log(`✅ Build triggered for ${jobPath}`);
  } else {
    console.error(`❌ Trigger failed: HTTP ${status}`);
  }
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  // Example 1: list all ELPA jobs with status
  console.log("=== ELPA Jobs ===");
  await listJobs("/job/ELPA");

  // Example 2: get last build log for application-service
  // console.log("\n=== application-service build log ===");
  // await getLog("/job/ELPA/job/application-service");

  // Example 3: trigger a build (uncomment carefully!)
  // console.log("\n=== Triggering build ===");
  // await triggerBuild("/job/ELPA/job/application-service");
}

main().catch((err) => {
  console.error("Fatal:", err.message);
  process.exit(1);
});
