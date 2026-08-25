'use strict';

const { app } = require('@azure/functions');
const df = require('durable-functions');

const { planReview } = require('../lib/review');

/**
 * `POST /api/start-review` — the Durable HTTP starter.
 *
 * Returns 202 with a `Location` header the moment the orchestration is queued.
 * The Logic App's HTTP action follows that header with its built-in
 * asynchronous pattern, so a review of any length is one billed action instead
 * of one per address, and none of it is subject to the 230-second Azure load
 * balancer cut that binds a synchronous HTTP-triggered function.
 *
 * The pre-stage rules run here, before the orchestration starts: internal and
 * malformed entries become findings on their own merit and are never queued for
 * enrichment, so they are never sent to AbuseIPDB and cost no API quota.
 */

const RETRY_AFTER_SECONDS = '10';

function badRequest(message) {
  return { status: 400, jsonBody: { error: message } };
}

app.http('startReview', {
  route: 'start-review',
  methods: ['POST'],
  authLevel: 'function',
  extraInputs: [df.input.durableClient()],
  handler: async (request, context) => {
    // The AbuseIPDB key is an app setting (a Key Vault reference), read only by
    // the activity. It is deliberately never accepted from the caller and never
    // placed in the orchestration input, because Durable persists that input to
    // the task hub's storage account as part of the replay history.
    if (!process.env.ABUSEIPDB_API_KEY) {
      context.error('ABUSEIPDB_API_KEY is not configured on the function app.');
      return {
        status: 500,
        jsonBody: { error: 'ABUSEIPDB_API_KEY is not configured on the function app.' },
      };
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return badRequest('Request body must be JSON.');
    }
    if (!body || typeof body !== 'object') return badRequest('Request body must be a JSON object.');
    if (typeof body.blobText !== 'string' || body.blobText === '') {
      return badRequest("'blobText' must be a non-empty string.");
    }

    const config = {
      rules: body.rules,
      batchSize: body.batchSize,
      maxFindings: body.maxFindings,
      parallelism: body.parallelism,
      maxAgeInDays: body.maxAgeInDays,
      timeoutMs: body.timeoutMs,
      maxAttempts: body.maxAttempts,
    };

    const plan = planReview(body.blobText, config);
    if (plan.ruleSummary.unknown.length) {
      // A typo in the ReviewRules parameter would otherwise silently disable a
      // rule and report a clean blocklist.
      return badRequest(`Unknown rule key(s) in 'rules': ${plan.ruleSummary.unknown.join(', ')}.`);
    }
    if (plan.counts.entries === 0) {
      return badRequest('The blob yielded no usable entries.');
    }

    const client = df.getClient(context);
    const instanceId = await client.startNew('reviewOrchestrator', {
      input: { plan, config, source: { container: body.container, blobPath: body.blobPath, runId: body.runId } },
    });
    context.log(
      `started review ${instanceId}: ${plan.counts.entries} entries, `
      + `${plan.counts.candidates} to enrich in ${plan.batches.length} batch(es), `
      + `${plan.counts.preFindings} flagged before enrichment`,
    );

    // A minimal 202 on purpose. `createCheckStatusResponse` would also hand back
    // the terminate and purge-history URLs, which have no business in a Logic
    // App run history.
    const management = client.createHttpManagementPayload(instanceId);
    return {
      status: 202,
      headers: {
        // returnInternalServerErrorOnFailure makes a failed orchestration answer
        // 500 rather than 200, so the polling Logic App action fails loudly
        // instead of reading a failure as an empty result set.
        // showInput=false keeps the whole plan (every batch of addresses) out of
        // the polled response, so the Logic App reads back only the result.
        Location: `${management.statusQueryGetUri}&showInput=false&returnInternalServerErrorOnFailure=true`,
        'Retry-After': RETRY_AFTER_SECONDS,
      },
      jsonBody: {
        instanceId,
        entries: plan.counts.entries,
        toEnrich: plan.counts.candidates,
        batches: plan.batches.length,
      },
    };
  },
});
