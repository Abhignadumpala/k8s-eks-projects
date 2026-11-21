// ───────────────────────────────────────────────
// Backend (tier 2): Node.js REST API for a simple task list
// Talks to MySQL (tier 3). Called by the frontend (tier 1) via /api.
// ───────────────────────────────────────────────
const express = require("express");
const mysql = require("mysql2/promise");
const client = require("prom-client");

const PORT = process.env.PORT || 8080;

// DB settings come from env vars (Kubernetes: ConfigMap + Secret)
const pool = mysql.createPool({
  host: process.env.DB_HOST || "localhost",
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER || "appuser",
  password: process.env.DB_PASSWORD || "apppass",
  database: process.env.DB_NAME || "tasksdb",
  waitForConnections: true,
  connectionLimit: 5,
});

// Prometheus metrics (used in Step 08 — monitoring)
client.collectDefaultMetrics();
const httpRequests = new client.Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status"],
});

const app = express();
app.use(express.json());
app.use((req, res, next) => {
  res.on("finish", () => {
    const route = req.route ? req.route.path : req.path;
    httpRequests.inc({ method: req.method, route, status: res.statusCode });
  });
  next();
});

// Liveness: is the process alive? (does NOT check the DB)
app.get("/api/health", (req, res) => {
  res.json({ status: "ok", version: process.env.APP_VERSION || "dev" });
});

// Readiness: can we reach the DB? (K8s sends traffic only when this is 200)
app.get("/api/ready", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "ready" });
  } catch (err) {
    res.status(503).json({ status: "db not reachable", error: err.code });
  }
});

app.get("/api/tasks", async (req, res) => {
  try {
    const [rows] = await pool.query("SELECT id, title, created_at FROM tasks ORDER BY id DESC");
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/api/tasks", async (req, res) => {
  const title = (req.body && req.body.title || "").trim();
  if (!title) return res.status(400).json({ error: "title is required" });
  try {
    const [result] = await pool.query("INSERT INTO tasks (title) VALUES (?)", [title]);
    res.status(201).json({ id: result.insertId, title });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.delete("/api/tasks/:id", async (req, res) => {
  try {
    await pool.query("DELETE FROM tasks WHERE id = ?", [req.params.id]);
    res.status(204).end();
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/metrics", async (req, res) => {
  res.set("Content-Type", client.register.contentType);
  res.end(await client.register.metrics());
});

// Create the table on startup. Retry because MySQL may still be starting.
async function initDb(retries = 30) {
  for (let i = 1; i <= retries; i++) {
    try {
      await pool.query(`CREATE TABLE IF NOT EXISTS tasks (
        id INT AUTO_INCREMENT PRIMARY KEY,
        title VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )`);
      console.log("DB ready, table 'tasks' exists");
      return;
    } catch (err) {
      console.log(`DB not ready (${err.code}), retry ${i}/${retries} in 5s...`);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
  console.log("DB still not reachable; API stays up, /api/ready will return 503");
}

if (require.main === module) {
  app.listen(PORT, () => console.log(`backend listening on :${PORT}`));
  initDb();
}

module.exports = { app, pool };
