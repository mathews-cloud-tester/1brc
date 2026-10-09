module.exports = (req, res) => {
  const raw = process.env.GREETING_SECRET;
  const value = raw === undefined || raw === "" ? "not set" : raw;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.statusCode = 200;
  res.end(JSON.stringify({ GREETING_SECRET: value }));
};
