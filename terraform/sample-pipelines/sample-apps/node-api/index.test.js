const request = require('supertest');
const app = require('./index');

describe('node-api', () => {
  it('returns status ok on /', async () => {
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok', service: 'node-api' });
  });

  it('returns healthy on /health', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ healthy: true });
  });
});
