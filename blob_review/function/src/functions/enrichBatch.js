'use strict';

const df = require('durable-functions');

const { runBatch } = require('../lib/review');

/**
 * The activity: one batch of addresses against AbuseIPDB.
 *
 * Activity functions answer to `functionTimeout` (10 minutes on the Consumption
 * plan), not to the 230-second load balancer cut that applies to HTTP triggers,
 * so a batch has roughly 30x the headroom it needs.
 *
 * The API key is read from the app setting here and nowhere else. It is never
 * an argument, so it never reaches the orchestration input and never lands in
 * the task hub's replay history. Never log it.
 */

df.app.activity('enrichBatch', {
  handler: async (input, context) => {
    const apiKey = process.env.ABUSEIPDB_API_KEY;
    if (!apiKey) {
      // Throwing beats returning an empty result: an unconfigured key must not
      // look like a batch with nothing to flag.
      throw new Error('ABUSEIPDB_API_KEY is not configured on the function app.');
    }

    const result = await runBatch(input.batch, { ...input.config, apiKey });
    context.log(
      `enrichBatch: requested=${result.counts.requested} checked=${result.counts.checked} `
      + `findings=${result.counts.findings} errors=${result.counts.errors} peakInFlight=${result.peakInFlight}`,
    );
    return result;
  },
});
