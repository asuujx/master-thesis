#!/usr/bin/env node
// Estimates infrastructure cost for a thesis run from run_metadata.json + per-iteration timings.
//
// Usage:
//   node scripts/estimate-costs.js metrics/aws/2026-...
//   node scripts/estimate-costs.js metrics/aws/2026-... metrics/azure/2026-... metrics/gcp/2026-...
//
// Output: formatted table to stdout + cost_estimate.json written into each run directory.

'use strict';
const fs   = require('fs');
const path = require('path');

// ── Pricing tables ─────────────────────────────────────────────────────────────
// On-demand / pay-as-you-go rates, May 2026. Sources:
//   AWS:   https://aws.amazon.com/ec2/pricing/on-demand/ (eu-central-1)
//          https://aws.amazon.com/eks/pricing/
//          https://aws.amazon.com/elasticloadbalancing/pricing/ (Classic LB)
//          https://aws.amazon.com/codebuild/pricing/
//   Azure: https://azure.microsoft.com/en-us/pricing/details/virtual-machines/linux/ (germanywestcentral)
//          https://azure.microsoft.com/en-us/pricing/details/load-balancer/
//          https://azure.microsoft.com/en-us/pricing/details/devops/azure-devops-services/
//   GCP:   https://cloud.google.com/compute/vm-instance-pricing (europe-west3)
//          https://cloud.google.com/kubernetes-engine/pricing
//          https://cloud.google.com/vpc/network-pricing#lb
//          https://cloud.google.com/build/pricing
const PRICING = {
  aws: {
    compute: {
      'm5.large': 0.096,      // $/node/hr, Linux on-demand, eu-central-1
    },
    controlPlane: 0.10,       // EKS managed cluster $/hr
    loadBalancer: 0.028,      // Classic ELB $/hr
    ciRunner: {
      perBuildMinute: 0.005,  // CodeBuild BUILD_GENERAL1_SMALL $/min, rounded up per build
    },
    estimatedTeardownSeconds: 600,
  },
  azure: {
    compute: {
      'Standard_D2s_v4': 0.115, // $/node/hr, Linux PAYG, germanywestcentral
    },
    controlPlane: 0.00,          // AKS control plane: free
    loadBalancer: 0.025,         // Standard LB $/hr
    ciRunner: {
      perBuildMinute: 0.008,     // Microsoft-hosted agent $/min
    },
    estimatedTeardownSeconds: 360,
  },
  gcp: {
    compute: {
      'n2-standard-2': 0.121, // $/node/hr, on-demand, europe-west3
    },
    controlPlane: 0.10,        // GKE Standard cluster $/hr — "first zonal cluster free" exemption removed for projects created after June 2024
    loadBalancer: 0.025,       // L4 Network LB forwarding rule $/hr
    ciRunner: {
      perBuildMinute: 0.003,   // Cloud Build default machine (n1-standard-1) $/min
    },
    estimatedTeardownSeconds: 300,
  },
};

// ── Helpers ────────────────────────────────────────────────────────────────────
function readJson(filePath) {
  try { return JSON.parse(fs.readFileSync(filePath, 'utf8')); }
  catch { return null; }
}

function fmtHours(seconds) {
  const h = seconds / 3600;
  return `${h.toFixed(2)} hr (${Math.round(seconds / 60)} min)`;
}

function fmtUsd(amount) {
  return `$${amount.toFixed(4)}`;
}

function padEnd(str, len) { return String(str).padEnd(len); }
function padStart(str, len) { return String(str).padStart(len); }

// ── Core estimator ─────────────────────────────────────────────────────────────
function estimateRun(runDir) {
  const absRunDir = path.resolve(runDir);
  const metadata  = readJson(path.join(absRunDir, 'run_metadata.json'));
  if (!metadata) {
    console.error(`ERROR: no run_metadata.json in ${runDir}`);
    process.exit(1);
  }

  const cloud   = metadata.cloud;
  const pricing = PRICING[cloud];
  if (!pricing) {
    console.error(`ERROR: no pricing entry for cloud "${cloud}". Add it to PRICING in this script.`);
    process.exit(1);
  }

  const computePrice = pricing.compute[metadata.nodeType];
  if (computePrice === undefined) {
    console.error(`ERROR: no compute price for node type "${metadata.nodeType}" under cloud "${cloud}".`);
    process.exit(1);
  }

  // ── Cluster uptime ──────────────────────────────────────────────────────────
  // Cluster exists from start of `tg apply` until `tg destroy` completes.
  // Teardown is not captured in run_metadata so we use a per-cloud estimate.
  const clusterSeconds =
    metadata.infrastructureProvisioningSeconds +
    metadata.appDeploySeconds +
    metadata.lbReadySeconds +
    metadata.totalTestSuiteDurationSeconds +
    pricing.estimatedTeardownSeconds;
  const clusterHours = clusterSeconds / 3600;

  // LB is provisioned after the cluster, active until teardown.
  const lbSeconds =
    metadata.lbReadySeconds +
    metadata.totalTestSuiteDurationSeconds +
    pricing.estimatedTeardownSeconds;
  const lbHours = lbSeconds / 3600;

  // ── CI runner billed minutes ────────────────────────────────────────────────
  // Each iteration is a separate build job; billing rounds up to nearest minute per job.
  let totalRunnerExecSeconds   = 0;
  let totalRunnerBilledMinutes = 0;
  let iterationsWithData       = 0;

  for (let i = 1; i <= metadata.iterationCount; i++) {
    const pt = readJson(path.join(absRunDir, `iteration-${i}`, 'provider_timings.json'));
    if (pt && pt.runnerExecutionSeconds > 0) {
      totalRunnerExecSeconds   += pt.runnerExecutionSeconds;
      totalRunnerBilledMinutes += Math.ceil(pt.runnerExecutionSeconds / 60);
      iterationsWithData++;
    }
  }

  // If some iterations are missing timing data, extrapolate from available ones.
  if (iterationsWithData > 0 && iterationsWithData < metadata.iterationCount) {
    const avgBilledMin = totalRunnerBilledMinutes / iterationsWithData;
    totalRunnerBilledMinutes = Math.round(avgBilledMin * metadata.iterationCount);
    totalRunnerExecSeconds   = Math.round(
      (totalRunnerExecSeconds / iterationsWithData) * metadata.iterationCount
    );
  }

  const runnerCost = totalRunnerBilledMinutes * pricing.ciRunner.perBuildMinute;

  // ── Cost breakdown ──────────────────────────────────────────────────────────
  const computeCost      = computePrice * metadata.nodeCount * clusterHours;
  const controlPlaneCost = pricing.controlPlane * clusterHours;
  const lbCost           = pricing.loadBalancer * lbHours;
  const totalCost        = computeCost + controlPlaneCost + lbCost + runnerCost;

  const result = {
    cloud:       cloud,
    environment: metadata.environment,
    nodeType:    metadata.nodeType,
    nodeCount:   metadata.nodeCount,
    region:      metadata.clusterRegion,
    iterations:  metadata.iterationCount,

    clusterUptimeSeconds:     clusterSeconds,
    lbActiveSeconds:          lbSeconds,
    totalRunnerExecSeconds:   totalRunnerExecSeconds,
    totalRunnerBilledMinutes: totalRunnerBilledMinutes,
    iterationsWithTimingData: iterationsWithData,

    pricing: {
      computePerNodeHour:       computePrice,
      controlPlanePerHour:      pricing.controlPlane,
      loadBalancerPerHour:      pricing.loadBalancer,
      ciRunnerPerMinute:        pricing.ciRunner.perBuildMinute,
      estimatedTeardownSeconds: pricing.estimatedTeardownSeconds,
    },

    costs: {
      computeUsd:      computeCost,
      controlPlaneUsd: controlPlaneCost,
      loadBalancerUsd: lbCost,
      ciRunnerUsd:     runnerCost,
      totalUsd:        totalCost,
    },
  };

  const outPath = path.join(absRunDir, 'cost_estimate.json');
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2));

  return result;
}

// ── Pretty printer ─────────────────────────────────────────────────────────────
function printTable(results) {
  const providerCol = 22;
  const numCol      = 14;

  const hr = '─'.repeat(providerCol + numCol * results.length + results.length + 1);

  const header = ['Component', ...results.map(r =>
    `${r.cloud.toUpperCase()} (${r.environment.toUpperCase()})`,
  )];

  const rows = [
    ['Node type',          ...results.map(r => r.nodeType)],
    ['Node count',         ...results.map(r => String(r.nodeCount))],
    ['Region',             ...results.map(r => r.region)],
    ['─'],
    ['Cluster uptime',     ...results.map(r => fmtHours(r.clusterUptimeSeconds))],
    ['LB active time',     ...results.map(r => fmtHours(r.lbActiveSeconds))],
    ['Runner billed min',  ...results.map(r => `${r.totalRunnerBilledMinutes} min`)],
    ['─'],
    ['Compute cost',       ...results.map(r => fmtUsd(r.costs.computeUsd))],
    ['Control plane cost', ...results.map(r => fmtUsd(r.costs.controlPlaneUsd))],
    ['Load balancer cost', ...results.map(r => fmtUsd(r.costs.loadBalancerUsd))],
    ['CI runner cost',     ...results.map(r => fmtUsd(r.costs.ciRunnerUsd))],
    ['─'],
    ['TOTAL COST',         ...results.map(r => fmtUsd(r.costs.totalUsd))],
  ];

  console.log('\n' + hr);
  console.log(
    padEnd(header[0], providerCol) +
    header.slice(1).map(h => padStart(h, numCol)).join(' ')
  );
  console.log(hr);

  for (const row of rows) {
    if (row[0] === '─') { console.log(hr); continue; }
    const [label, ...vals] = row;
    console.log(padEnd(label, providerCol) + vals.map(v => padStart(v, numCol)).join(' '));
  }
  console.log(hr);

  console.log('\nPricing assumptions (on-demand, no reserved/spot discounts):');
  for (const r of results) {
    const p = r.pricing;
    console.log(
      `  ${r.cloud.toUpperCase()}: ` +
      `${r.nodeType} $${p.computePerNodeHour}/node/hr · ` +
      `control plane $${p.controlPlanePerHour}/hr · ` +
      `LB $${p.loadBalancerPerHour}/hr · ` +
      `CI runner $${p.ciRunnerPerMinute}/min`
    );
  }
  console.log(`  Teardown time estimated (not measured in run_metadata): ~${
    results.map(r => `${r.pricing.estimatedTeardownSeconds}s (${r.cloud})`).join(', ')
  }.`);
  console.log(`  Storage and data transfer costs omitted (negligible for test workloads).\n`);
}

// ── Main ───────────────────────────────────────────────────────────────────────
const runDirs = process.argv.slice(2);
if (runDirs.length === 0) {
  console.error('Usage: node scripts/estimate-costs.js <run-dir> [<run-dir> ...]');
  console.error('Example: node scripts/estimate-costs.js metrics/aws/2026-05-09_21-32-06');
  process.exit(1);
}

const results = runDirs.map(estimateRun);
printTable(results);

for (const [i] of results.entries()) {
  const outPath = path.join(path.resolve(runDirs[i]), 'cost_estimate.json');
  console.log(`Wrote: ${outPath}`);
}
