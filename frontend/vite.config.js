import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import { SignatureV4 } from '@smithy/signature-v4';
import { HttpRequest } from '@smithy/protocol-http';
import { Sha256 } from '@aws-crypto/sha256-js';
import { defaultProvider } from '@aws-sdk/credential-provider-node';

const ReactCompilerConfig = {
  target: '19',
};

/**
 * Vite dev-server plugin that proxies `/api/*` to the dashboard's API
 * Gateway endpoint, signing each request with SigV4 using the developer's
 * local AWS credentials.
 *
 * This is what keeps the API non-public: the API Gateway routes use
 * `authorization_type = AWS_IAM`, and only this signed-proxy path (or any
 * other SigV4-aware client) can call them. The browser never sees AWS
 * credentials — they live on the developer's machine and are loaded via
 * the standard AWS credential chain (env vars, ~/.aws/credentials, SSO).
 *
 * Required env (frontend/.env):
 *   VITE_API_URL        - https://<api-id>.execute-api.<region>.amazonaws.com
 *
 * Optional:
 *   VITE_AWS_REGION     - region for signing; falls back to the host or AWS_REGION
 *   AWS_PROFILE         - shared-credentials profile to use
 *   AWS_REGION          - default region for the credential chain
 */
function awsSigV4Proxy(env) {
  return {
    name: 'aws-sigv4-proxy',
    configureServer(server) {
      const rawApiUrl = env.VITE_API_URL;
      if (!rawApiUrl) {
        console.warn(
          '[aws-sigv4-proxy] VITE_API_URL is not set. Create frontend/.env with ' +
          'VITE_API_URL=https://<api-id>.execute-api.<region>.amazonaws.com'
        );
        return;
      }

      let apiUrl;
      try {
        apiUrl = new URL(rawApiUrl);
      } catch (err) {
        console.error(`[aws-sigv4-proxy] VITE_API_URL is not a valid URL: ${rawApiUrl}`);
        return;
      }

      // Derive region from VITE_AWS_REGION, then from the API hostname
      // (execute-api URLs are <id>.execute-api.<region>.amazonaws.com), then
      // from AWS_REGION / AWS_DEFAULT_REGION, then us-east-1 as a last resort.
      const hostRegion = apiUrl.hostname.split('.')[2];
      const region =
        env.VITE_AWS_REGION ||
        hostRegion ||
        process.env.AWS_REGION ||
        process.env.AWS_DEFAULT_REGION ||
        'us-east-1';

      const signer = new SignatureV4({
        credentials: defaultProvider(),
        region,
        service: 'execute-api',
        sha256: Sha256,
      });

      console.log(
        `[aws-sigv4-proxy] proxying /api/* -> ${apiUrl.origin} (region=${region})`
      );

      server.middlewares.use('/api', async (req, res) => {
        // req.url is the path + query relative to the /api mount.
        const incoming = new URL(`http://placeholder${req.url || '/'}`);

        const query = {};
        for (const [k, v] of incoming.searchParams) {
          if (query[k] === undefined) query[k] = v;
          else if (Array.isArray(query[k])) query[k].push(v);
          else query[k] = [query[k], v];
        }

        // For POST/PUT/PATCH, buffer the request body so SigV4 can hash it
        // and we can forward it upstream. GET/HEAD/DELETE skip this.
        const hasBody = !['GET', 'HEAD', 'DELETE', 'OPTIONS'].includes(
          (req.method || 'GET').toUpperCase()
        );
        let bodyBuffer;
        if (hasBody) {
          bodyBuffer = await new Promise((resolve, reject) => {
            const chunks = [];
            req.on('data', (chunk) => chunks.push(chunk));
            req.on('end', () => resolve(Buffer.concat(chunks)));
            req.on('error', reject);
          });
        }

        const upstreamPath =
          apiUrl.pathname.replace(/\/$/, '') + incoming.pathname;

        const upstreamHeaders = {
          host: apiUrl.hostname,
          accept: 'application/json',
        };
        if (hasBody && bodyBuffer && bodyBuffer.length > 0) {
          upstreamHeaders['content-type'] =
            req.headers['content-type'] || 'application/json';
        }

        const upstream = new HttpRequest({
          method: req.method || 'GET',
          protocol: apiUrl.protocol,
          hostname: apiUrl.hostname,
          port: apiUrl.port ? Number(apiUrl.port) : undefined,
          path: upstreamPath,
          query,
          headers: upstreamHeaders,
          body: hasBody && bodyBuffer ? bodyBuffer : undefined,
        });

        try {
          const signed = await signer.sign(upstream);

          const search = new URLSearchParams();
          for (const [k, v] of Object.entries(signed.query || {})) {
            if (Array.isArray(v)) v.forEach((x) => search.append(k, x));
            else if (v !== undefined && v !== null) search.append(k, v);
          }
          const qs = search.toString();
          const finalUrl = `${apiUrl.origin}${signed.path}${qs ? `?${qs}` : ''}`;

          const upstreamRes = await fetch(finalUrl, {
            method: signed.method,
            headers: signed.headers,
            body: hasBody && bodyBuffer ? bodyBuffer : undefined,
          });

          res.statusCode = upstreamRes.status;
          upstreamRes.headers.forEach((value, key) => {
            // Drop hop-by-hop headers that confuse Node's http server.
            const lower = key.toLowerCase();
            if (lower === 'transfer-encoding' || lower === 'connection') return;
            res.setHeader(key, value);
          });
          const body = Buffer.from(await upstreamRes.arrayBuffer());
          res.end(body);
        } catch (err) {
          console.error('[aws-sigv4-proxy] forward failed:', err);
          res.statusCode = 502;
          res.setHeader('content-type', 'application/json');
          res.end(
            JSON.stringify({
              error: 'proxy_error',
              message: String(err?.message || err),
              hint:
                'Check that your local AWS credentials are valid and that ' +
                'execute-api:Invoke on the API ARN is granted (attach ' +
                'the ApiInvokePolicyArn stack output).',
            })
          );
        }
      });
    },
  };
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  return {
    plugins: [
      react({
        babel: {
          plugins: [
            ['babel-plugin-react-compiler', ReactCompilerConfig],
          ],
        },
      }),
      awsSigV4Proxy(env),
    ],
  };
});
