# Local Keycloak for the FHIR SMART authorizer

This stack issues SMART access tokens for the FHIR Server API. The authorizer checks the token `iss`, signature, and a `client_id` claim, then grants the token `scope`. A `patient/` scope also requires a `patient` claim. A `user/` scope is dropped unless the issuer's registry entry sets `allow_user_scopes` to true. Realm roles are labels in the admin console. They do not grant access. The collection requests the scope string that matches each user's role. The API does not check `aud`.

Passwords below are for this local realm only.

## Start Keycloak

From this directory:

```bash
chmod +x generate-dev-cert.sh
./generate-dev-cert.sh
docker compose up -d
```

Wait until `docker compose ps` shows the container healthy. The first start imports every file in `realm/`: `fhir-realm.json`, `fhir-user-realm.json`, and `untrusted-realm.json`.

| | |
| --- | --- |
| Admin console | The host you opened, such as `http://<ec2-host>:8080` or `https://localhost:8444` |
| Admin user | `admin` |
| Admin password | `9f4ae588a43b3f830996082ff43afba0` |
| Realm | `fhir` |
| Token issuer | `https://localhost:8444/realms/fhir` |

`docker compose down` removes the container. The next `up` imports the realm again. `restart` keeps the imported data.

The certificate is self-signed. Postman needs SSL verification turned off for localhost, or the cert in `certs/server.crt` trusted. Mint tokens from `https://localhost:8444` so `iss` matches the registry. A token from `http://localhost:8080` can carry a different issuer and will be `unknown_issuer`.

## Point the API at this issuer

1. Copy `issuer-registry.local.json`.
2. Replace `allowed_tenant_guids` in each entry with the org guid you will call. That org needs an ACTIVE DRLS assignment whose addons include `fhir_api`, and `fhir_store.hosting` set to `itiliti`. For the Encounter request in the collection, set `allowedResourceTypes` to `Patient,Observation,Parameters`.
   The file holds two local entries: realm `fhir` (`allow_user_scopes` false) and realm `fhir-user` (`allow_user_scopes` true).
3. Store the JSON as the secret `{stage}-FHIR_SERVER_REGISTRY`. `STAGE` is the stage name, for example `dev`.
4. Start the dev server with the cert trusted, from the repo root:

```bash
export NODE_EXTRA_CA_CERTS="$PWD/fhir-server/keycloak/certs/server.crt"
npm run start:dev
```

The authorizer fetches the OpenID configuration URL, then the `jwks_uri` it advertises. Both must be HTTPS. It accepts the token `alg` only when that document lists it and the alg is asymmetric (`RS*`, `PS*`, or `ES*`). `HS*` and `none` are rejected even if discovery lists them. The registry and the discovery document are cached for 60 seconds.

Local routes look like `http://localhost:3000/fhir/{guid}/r4/Patient`. Put the same guid in the Postman variable `tenantGuid`. Leave `otherTenantGuid` as a different uuid.

## Generate a token

Password grant. The password equals the username.

```bash
curl -sk -X POST 'https://localhost:8444/realms/fhir/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'client_id=fhir-smart-local' \
  -d 'client_secret=fhir-smart-local-secret' \
  -d 'username=patient-reader' \
  -d 'password=patient-reader' \
  -d 'scope=openid patient/Patient.rs'
```

Decode the payload and check:

- `iss` is `https://localhost:8444/realms/fhir`
- `client_id` is `fhir-smart-local`
- `tenant_id` is `bb9c3627-1744-4e75-8655-6a5881b1c6a5`, the same guid as the `/fhir/{guid}` path
- `scope` contains the SMART scope you requested
- `patient` is present only for users who have that attribute

Keycloak still puts `fhir-local-api` in `aud`. The API ignores that claim.

Call the API with `Authorization: Bearer <access_token>`.

The registered client is `fhir-smart-local`. `fhir-unregistered-client` (secret `fhir-unregistered-client-secret`) signs tokens in the same realm with a different `client_id`. Those tokens are `client_mismatch`.

## Users

Every user below is in realm `fhir` except `user-scope-reader`. The role name matches the username. Request `openid` plus the scopes in the table.

| User | Patient claim | Requested SMART scopes | What the API allows |
| --- | --- | --- | --- |
| `system-admin` | none | `system/Patient.cruds` `system/Observation.rs` `system/Parameters.c` | Patient create, read, search, update, patch, and delete. Observation read and search. Parameters create, including bulk create. Observation create is denied. |
| `system-reader` | none | `system/Patient.read` `system/Observation.read` | v1 `.read` becomes read and search. Patient and Observation GET only. Creates are denied. |
| `system-wildcard` | none | `system/*.read` | Grants `system/*.rs` for every allowlisted type. Parameters create is denied. Encounter is `type_not_allowed` when the allowlist omits it. |
| `patient-deleter` | none | `system/Patient.d` | DELETE Patient. GET is denied. |
| `patient-patcher` | none | `system/Patient.u` | PUT and PATCH Patient. GET is denied. |
| `patient-reader` | `patient-100` | `patient/Patient.rs` | GET and search that Patient. `Patient/patient-200` is 404. Other types are denied. |
| `observation-reader` | `patient-200` | `patient/Observation.rs` | Observation search is confined to `subject=Patient/patient-200`. `_include` is denied. A foreign Observation id is 404. Patient reads are denied. |
| `observation-writer` | `patient-100` | `patient/Observation.cu` | Create and update an Observation whose subject is `Patient/patient-100`. Another subject is 403. A client-supplied id is 400. GET is denied. JSON Patch is 403 when the resource is in the compartment. |
| `patient-creator` | `patient-100` | `patient/Patient.c` | POST Patient is 403. A patient scope cannot create a Patient. |
| `user-scope` | none | `user/Patient.rs` | 403. `user/` scopes are dropped, and nothing remains. |
| `user-and-system` | none | `system/Patient.rs` `user/Patient.rs` | The `user/` scope is dropped. Patient read and search remain. |
| `no-smart-scope` | none | none (`openid` only) | 403 `insufficient_scope`. |
| `bad-patient-id` | `bad id` | `patient/Patient.rs` | 403. The patient claim is not a FHIR id. |
| `granular-reader` | `patient-100` | `patient/Observation.rs?category=http://terminology.hl7.org/CodeSystem/observation-category\|vital-signs` | Observation search is confined to the launch patient and to vital-signs. A client `category` param is ANDed, never replaced. A stored Observation outside the constraint is 404. |
| `granular-writer` | `patient-100` | `patient/Observation.cu?status=final` | Create and update an Observation with `status` `final` for the launch patient. Another status is 403 `insufficient_scope`. JSON Patch is 403. |

`user-scope-reader` / `user-scope-reader` is in realm `fhir-user`, client `fhir-smart-local-user` (secret `fhir-smart-local-user-secret`). It requests `user/Patient.rs`. The registry entry for that issuer sets `allow_user_scopes` true, so the scope is tenant-wide Patient read and search. The same scope from `user-scope` in realm `fhir` is 403, because that entry leaves the flag off. Each realm has its own issuer URL, and the issuer URL is the registry key, so the opt-in cannot share a client with realm `fhir`.

`outsider` / `outsider` is in realm `untrusted`. Its issuer is `https://localhost:8444/realms/untrusted`, which is not in the registry, so the API returns 401 `unknown_issuer`.

## Authorizer results

| Case | Status | diagnostics |
| --- | --- | --- |
| No Authorization header | 401 | `missing_token` |
| Not a JWT, bad signature, or a signing alg discovery does not accept | 401 | `invalid_token` |
| Token from realm `untrusted` | 401 | `unknown_issuer` |
| Client `fhir-unregistered-client` | 401 | `client_mismatch` |
| Guid not in `allowed_tenant_guids` | 401 | `tenant_mismatch` |
| No remaining SMART scope, or a patient grant the handler cannot confine | 403 | `insufficient_scope` |
| Resource type missing from the tenant allowlist | 403 | `type_not_allowed` |
| Patient id outside the launch patient | 404 | `Resource is not known` |

To test expiry, set the realm access token lifespan to 60 seconds in Realm settings → Tokens, mint a token, wait, and call again. The result is 401 `expired`. Keycloak always sets `exp`, so a missing `exp` is not produced here.

The token `scope` is the grant. The registry does not list scopes. `system/Observation.rs` does not include create. `patient/Observation.cu` does not include read, search, or delete. A `patient/` scope reads the patient id from the `patient` claim.

## `allow_user_scopes`

A registry field on each issuer entry. It defaults to false.

- Absent or false: `user/` scopes are dropped. A token whose only scopes are `user/` is 403 `insufficient_scope`.
- True: `user/X.v` behaves as tenant-wide access to `X` for those verbs. The tenancy layer still keeps the call inside the URL tenant. The API has no user-to-patient model, so there is no per-user narrowing.

Set it only for an issuer whose `user/` scopes go to the tenant's own staff.

## Granular scope grammar

```text
{context}/{Type}.{verbs}?{query}
```

- `context` is `patient`, `user`, or `system`. `Type` is a resource type or `*`. `verbs` is `read`, `write`, `*`, or letters from `cruds`.
- `query` is one or more `name=value` pairs joined with `&`. The name must be a lowercase token param the server can evaluate: `category`, `code`, `status`, `clinical-status`, or `verification-status`. Any other name denies.
- `?` and `|` are legal in a scope token, so the Keycloak client scope name is the scope text itself. Send it URL-encoded in the token request.
- Search appends the constraint to the client query. Two scopes with the same single param name merge into one comma list. Two scopes with different params make the search 403.
- Instance read outside the constraint is 404. A create or update body outside it is 403. JSON Patch under a constrained grant is 403. A constrained delete reads the resource first and 404s on a mismatch.

The full rules and limits are in `agent_docs/fhir_smart_scopes.md`.

## Postman

Import both files in `postman/`:

- `fhir-smart-local.postman_collection.json`
- `fhir-smart-local.postman_environment.json`

Set `tenantGuid` to the guid you stored in the registry. Run folder **1. Tokens** first. It saves each access token on the collection. Then run **2. Authorizer denials**, **3. System scopes**, **4. Patient compartment**, and **5. User scopes and granular scopes**.

Folder 2 should pass with Keycloak and the dev server up, before a FHIR store has data. Folders 3 and 4 treat 200, 201, 204, 404, and a store error as an allowed call. They fail on 401 and on 403 `insufficient_scope`, `type_not_allowed`, `tenant_disabled`, or `compartment`.

Folder 5 needs the realm `fhir-user` registry entry for the user-scope-honored request. Its granular read request returns 404 for an id that does not exist, so it checks the status and message, not the mismatch branch. Seed an Observation outside the constraint to exercise that branch.
