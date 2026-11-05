// Unit tests run in CI before the image is built (no DB needed).
// Run locally: npm test
const { test, after } = require("node:test");
const assert = require("node:assert");
const { app, pool } = require("../server");

const server = app.listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

after(async () => {
  server.close();
  await pool.end();
});

test("GET /api/health returns ok", async () => {
  const res = await fetch(`${base}/api/health`);
  assert.strictEqual(res.status, 200);
  const body = await res.json();
  assert.strictEqual(body.status, "ok");
});

test("POST /api/tasks without title returns 400", async () => {
  const res = await fetch(`${base}/api/tasks`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });
  assert.strictEqual(res.status, 400);
});

test("GET /metrics exposes Prometheus metrics", async () => {
  const res = await fetch(`${base}/metrics`);
  assert.strictEqual(res.status, 200);
  assert.match(await res.text(), /http_requests_total/);
});
