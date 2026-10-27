# keys/

Local TLS material for PostgreSQL. **Nothing in this directory is tracked by git**
except `generate-certs.sh` and this README.

## What lives here

| File | Purpose |
|---|---|
| `rootCA.crt` / `rootCA.key` | Local certificate authority |
| `server.crt` / `server.key` | PostgreSQL server certificate (`CN=db.homestead.systems`) |
| `client.crt` / `client.key` | Client certificate for mutual TLS (`CN=infisical`) |
| `*.csr`, `rootCA.srl` | Intermediate artifacts, not needed at runtime |

## Generate a fresh set

```bash
./keys/generate-certs.sh
```

Overridable via env: `CA_CN`, `SERVER_CN`, `CLIENT_CN`, `SERVER_SAN`, `DAYS`, `KEY_BITS`.

## How the container gets the certs

The image does **not** bake certificates in. `container/entrypoint.sh` writes the
three files from environment variables before starting PostgreSQL:

| Env var | Written to |
|---|---|
| `SERVER_CRT`   | `/var/lib/postgresql/server.crt` |
| `SERVER_KEY`   | `/var/lib/postgresql/server.key` |
| `ROOT_CA_CRT`  | `/var/lib/postgresql/rootCA.crt` |

`container/postgresql.conf` points `ssl_cert_file` / `ssl_key_file` / `ssl_ca_file`
at those paths, and the entrypoint sets `chmod 600` + `chown postgres:postgres`.

`generate-certs.sh` prints the ready-to-paste env vars at the end.

## Warning

These are real credentials. If a key ever lands in git history, rotate it —
`git rm` alone does not remove it from history.
