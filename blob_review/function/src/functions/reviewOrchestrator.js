'use strict';

const df = require('durable-functions');

const { summarise } = require('../lib/review');

/**
 * The orchestrator. Walks the batches one at a time.
 *
 * Sequential is deliberate: in-flight AbuseIPDB requests then equal exactly the
 * activity's own `parallelism` (50 by default), because only one activity is
 * ever pending. Fanning batches out in parallel would multiply that by however
 * many activities the host chose to run.
 *
 * Batching also checkpoints: a host restart resumes at the next batch rather
 * than re-scanning the blocklist, and no single activity runs long enough to
 * approach the Consumption plan's 10-minute function timeout.
 *
 * Must stay deterministic — no Date.now(), no Math.random(), no I/O outside
 * callActivity. `summarise` is pure.
 */

const FIRST_RETRY_MS = 5000;
const MAX_ATTEMPTS = 3;

df.app.orchestration('reviewOrchestrator', function* reviewOrchestrator(context) {
  const { plan, config } = context.df.getInput();
  const retry = new df.RetryOptions(FIRST_RETRY_MS, MAX_ATTEMPTS);

  const results = [];
  let flagged = plan.counts.preFindings;
  let checked = 0;

  for (let index = 0; index < plan.batches.length; index += 1) {
    context.df.setCustomStatus({
      stage: 'enriching',
      batch: index + 1,
      batches: plan.batches.length,
      checked,
      flagged,
    });
    const result = yield context.df.callActivityWithRetry('enrichBatch', retry, {
      batch: plan.batches[index],
      config,
    });
    results.push(result);
    checked += result.counts.checked;
    flagged += result.counts.findings;
  }

  context.df.setCustomStatus({ stage: 'summarising', batches: plan.batches.length, checked, flagged });
  return summarise(plan, results, config);
});
