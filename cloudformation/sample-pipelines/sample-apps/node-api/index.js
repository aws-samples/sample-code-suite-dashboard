// Tiny Express service used as a stand-in for a real Node backend.
// CodeBuild runs `npm test`; the artifact is the source tree.

const express = require('express');

const app = express();

app.get('/', (_req, res) => {
  res.json({ status: 'ok', service: 'node-api' });
});

app.get('/health', (_req, res) => {
  res.json({ healthy: true });
});

if (require.main === module) {
  const port = process.env.PORT || 8080;
  app.listen(port, () => console.log(`node-api listening on :${port}`));
}

module.exports = app;
