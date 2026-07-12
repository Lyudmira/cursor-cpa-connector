# Nginx Buffering Breaks Cursor SSE Streaming

## Symptom

When Cursor sends a streaming request through an Nginx reverse proxy, output may arrive in periodic batches instead of continuously. The UI appears to stall for a while and then suddenly displays multiple chunks at once. Long read timeouts do not fix this behavior because the connection remains open; the problem is response buffering rather than request timeout.

## Cause

Nginx enables upstream response buffering by default:

```nginx
proxy_buffering on;
```

This default is useful for ordinary HTTP responses, but it conflicts with Server-Sent Events and other incremental streaming protocols. Nginx may collect small upstream chunks before forwarding them to Cursor, hiding the cadence produced by the Responses API.

The issue applies only when an Nginx layer sits between Cursor and Bifrost. A client connected directly to Bifrost does not need this Nginx-specific fix.

## Required configuration

Apply the streaming settings to every Nginx `location` that can carry Cursor Responses or Chat Completions traffic:

```nginx
location /cursor/ {
    proxy_pass http://bifrost-upstream/cursor/;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection "";

    proxy_buffering off;
    proxy_cache off;
    proxy_request_buffering off;
    chunked_transfer_encoding on;
    gzip off;
    add_header X-Accel-Buffering no;

    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
}
```

If `/cursor/v1/responses` is rewritten to Bifrost's native `/v1/responses` endpoint in a separate location, apply the same settings there as well:

```nginx
location ^~ /cursor/v1/responses {
    proxy_pass http://bifrost-upstream/v1/responses;
    proxy_http_version 1.1;
    proxy_set_header Connection "";

    proxy_buffering off;
    proxy_cache off;
    proxy_request_buffering off;
    chunked_transfer_encoding on;
    gzip off;
    add_header X-Accel-Buffering no;

    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
}
```

`proxy_buffering off` is the essential change for the observed batched-output symptom. The surrounding directives remove other common sources of buffering or stream transformation and make the intended SSE behavior explicit.

## Verification

Validate the configuration before reloading Nginx:

```powershell
docker exec edge-proxy nginx -t
docker exec edge-proxy nginx -s reload
```

Then confirm the active configuration contains the streaming directives:

```powershell
docker exec edge-proxy nginx -T
```

Finally, run a response that produces output for long enough to observe delivery cadence. Tokens should arrive incrementally rather than in periodic batches. A pause during a model's internal reasoning phase can still occur when the upstream emits no events; that is different from Nginx receiving chunks and withholding them in a buffer.