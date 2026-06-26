#!/usr/bin/env python3
"""
awscall.py — tiny SigV4-signed HTTP client for execute-api endpoints.

The dashboard API is protected by API Gateway AWS_IAM authorization, so
plain curl gets back 403. This helper signs requests with botocore using
your local AWS credential chain (env vars, ~/.aws/credentials, SSO, etc.).

Usage:
    python3 scripts/awscall.py <method> <url> [--region us-east-1] [--body @file|-|literal]

Examples:
    python3 scripts/awscall.py GET https://abc123.execute-api.us-east-1.amazonaws.com/accounts
    AWS_PROFILE=my-profile python3 scripts/awscall.py GET "$URL/pipelines"

Outputs the response body to stdout; non-2xx responses exit non-zero.

Dependencies: boto3 (already used by other helpers in this repo).
"""
from __future__ import annotations

import argparse
import sys
import urllib.parse
import urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest


def derive_region_from_host(host: str) -> str | None:
    # execute-api URLs look like <id>.execute-api.<region>.amazonaws.com
    parts = host.split('.')
    if len(parts) >= 4 and parts[1] == 'execute-api':
        return parts[2]
    return None


def call(method: str, url: str, region: str | None, body: bytes | None) -> int:
    parsed = urllib.parse.urlparse(url)
    if not parsed.scheme or not parsed.netloc:
        print(f'awscall: invalid URL: {url}', file=sys.stderr)
        return 2

    region = region or derive_region_from_host(parsed.hostname or '') or 'us-east-1'

    session = boto3.Session()
    creds = session.get_credentials()
    if creds is None:
        print(
            'awscall: no AWS credentials found. '
            'Configure AWS_PROFILE / AWS_ACCESS_KEY_ID / SSO and try again.',
            file=sys.stderr,
        )
        return 2

    aws_req = AWSRequest(method=method, url=url, data=body or b'')
    SigV4Auth(creds.get_frozen_credentials(), 'execute-api', region).add_auth(aws_req)

    headers = dict(aws_req.headers.items())
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            sys.stdout.buffer.write(resp.read())
            return 0 if 200 <= resp.status < 300 else 1
    except urllib.error.HTTPError as e:
        sys.stderr.buffer.write(e.read())
        sys.stderr.write(f'\nawscall: HTTP {e.code} {e.reason}\n')
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description='SigV4-signed HTTP client for execute-api.')
    parser.add_argument('method', help='HTTP method (GET, POST, ...).')
    parser.add_argument('url', help='Full URL including scheme and path.')
    parser.add_argument('--region', help='Override signing region (default: derived from URL).')
    parser.add_argument(
        '--body',
        help='Request body. Use @path to read from a file, - to read from stdin, or pass the literal string.',
    )
    args = parser.parse_args()

    body: bytes | None = None
    if args.body is not None:
        if args.body == '-':
            body = sys.stdin.buffer.read()
        elif args.body.startswith('@'):
            with open(args.body[1:], 'rb') as f:
                body = f.read()
        else:
            body = args.body.encode('utf-8')

    return call(args.method.upper(), args.url, args.region, body)


if __name__ == '__main__':
    sys.exit(main())
