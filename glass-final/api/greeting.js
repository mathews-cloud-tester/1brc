module.exports = (req, res) => {
  const value = process.env.GREETING_SECRET;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.statusCode = 200;
  res.end(JSON.stringify({ GREETING_SECRET: value ? value : "not set" }));
};
