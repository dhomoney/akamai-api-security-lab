import os
import sys
import random
import secrets

from locust import FastHttpUser, between, task

KONG_ALB_DNS = os.environ.get("KONG_ALB_DNS")
NGINX_ALB_DNS = os.environ.get("NGINX_ALB_DNS")
MULE_ALB_DNS = os.environ.get("MULE_ALB_DNS")
if not KONG_ALB_DNS or not NGINX_ALB_DNS:
    sys.exit("ERROR: KONG_ALB_DNS and NGINX_ALB_DNS must be set. Run via 'make traffic'.")

KONG_BASE = f"http://{KONG_ALB_DNS}"
NGINX_BASE = f"http://{NGINX_ALB_DNS}"
MULE_BASE = f"http://{MULE_ALB_DNS}" if MULE_ALB_DNS else None

# ─── Identity pooling ────────────────────────────────────────────────────────
#
# Noname's behavioural engine learns per-source baselines from the diversity
# of authenticated user identities it sees, not just from request volume. To
# get to ~2000 distinct end-users per API without spinning up 2000 concurrent
# locust instances (which would flood t3.medium hosts), each authenticated
# User class maintains a class-level pool of registered identities:
#
#   1. on_start: register up to USER_POOL_SEED_PER_INSTANCE fresh identities
#      and append to the shared pool — capped at USER_POOL_SIZE total.
#   2. Every IDENTITY_ROTATION_INTERVAL tasks, the instance rotates: if the
#      pool is below target, register a new identity and use it; otherwise
#      pick a random existing pool entry. This means the pool grows during
#      the run and identities get reused once the target is hit.
#
# With default 50 concurrent users (TRAFFIC_USERS=50) and the per-class
# weight distribution, each authenticated class gets ~6–11 instances; the
# initial seed phase puts ~300–550 entries in the pool within ~10 seconds,
# and rotation tops it up to USER_POOL_SIZE over the next several minutes.
# Bump USER_POOL_SEED_PER_INSTANCE for faster initial fill.

USER_POOL_SIZE = int(os.environ.get("USER_POOL_SIZE", "2000"))
USER_POOL_SEED_PER_INSTANCE = int(os.environ.get("USER_POOL_SEED_PER_INSTANCE", "50"))
IDENTITY_ROTATION_INTERVAL = int(os.environ.get("IDENTITY_ROTATION_INTERVAL", "5"))


def uid():
    return secrets.token_hex(4)


def gql(query):
    return {"query": query}


class HttpBinUser(FastHttpUser):
    """Hits go-httpbin (pixi slot) via Kong. Stateless — no auth needed."""

    host = KONG_BASE
    weight = 3
    wait_time = between(0.5, 2)

    @task(5)
    def get_get(self):
        self.client.get("/pixi/get")

    @task(4)
    def post_post(self):
        self.client.post("/pixi/post", json={"id": uid(), "value": "test"})

    @task(3)
    def get_uuid(self):
        self.client.get("/pixi/uuid")

    @task(3)
    def get_json(self):
        self.client.get("/pixi/json")

    @task(3)
    def get_headers(self):
        self.client.get("/pixi/headers")

    @task(2)
    def put_put(self):
        self.client.put("/pixi/put", json={"key": uid()})

    @task(2)
    def post_anything(self):
        self.client.post("/pixi/anything", json={"x": uid()})

    @task(2)
    def get_ip(self):
        self.client.get("/pixi/ip")

    @task(1)
    def get_404(self):
        with self.client.get("/pixi/status/404", catch_response=True) as r:
            if r.status_code == 404:
                r.success()

    @task(1)
    def get_500(self):
        with self.client.get("/pixi/status/500", catch_response=True) as r:
            if r.status_code == 500:
                r.success()


class VAmPIUser(FastHttpUser):
    """VAmPI REST API via NGINX. Pools authenticated identities across the run
    so Noname sees a diverse set of users rather than one per locust instance.
    """

    host = NGINX_BASE
    weight = 2
    wait_time = between(0.5, 2)

    # Class-level — every VAmPIUser instance shares this pool and the
    # DB-init flag.
    _identity_pool = []
    _db_initialized = False

    def on_start(self):
        if not VAmPIUser._db_initialized:
            # VAmPI ships with empty SQLite — /createdb seeds the users/books
            # tables. Without this, every other call returns 500 ("no such
            # table: users").
            with self.client.get("/vampi/createdb",
                                 name="/vampi/createdb (init)",
                                 catch_response=True) as r:
                if r.status_code in (200, 404):
                    r.success()
            VAmPIUser._db_initialized = True

        # Seed phase: contribute up to N identities to the shared pool.
        # Stops early if the pool is already at target size (other instances
        # have done the work).
        for _ in range(USER_POOL_SEED_PER_INSTANCE):
            if len(VAmPIUser._identity_pool) >= USER_POOL_SIZE:
                break
            ident = self._register_identity()
            if ident:
                VAmPIUser._identity_pool.append(ident)

        self._tasks_since_rotation = 0
        self._activate_random_pool_identity()

    def _register_identity(self):
        username = f"user_{uid()}"
        password = "LabPass123!"
        with self.client.post("/vampi/users/v1/register",
                              json={
                                  "username": username,
                                  "password": password,
                                  "email": f"{username}@lab.test",
                              },
                              name="/vampi/users/v1/register",
                              catch_response=True) as r:
            # 400 = duplicate username (very unlikely with token_hex(4))
            if r.status_code in (200, 201, 400):
                r.success()
        resp = self.client.post("/vampi/users/v1/login",
                                name="/vampi/users/v1/login",
                                json={"username": username, "password": password})
        if resp.status_code != 200:
            return None
        token = resp.json().get("auth_token")
        if not token:
            return None
        return {
            "username": username,
            "password": password,
            "token": token,
            "auth": {"Authorization": f"Bearer {token}"},
        }

    def _activate(self, ident):
        self.username = ident["username"]
        self.password = ident["password"]
        self.auth = ident["auth"]

    def _activate_random_pool_identity(self):
        if VAmPIUser._identity_pool:
            self._activate(random.choice(VAmPIUser._identity_pool))
        else:
            # Pool is empty (registration failed during seed) — fall back to
            # an unauthenticated session. Most tasks tolerate missing auth.
            self.username = f"user_{uid()}"
            self.password = "LabPass123!"
            self.auth = {}

    def _maybe_rotate(self):
        self._tasks_since_rotation += 1
        if self._tasks_since_rotation < IDENTITY_ROTATION_INTERVAL:
            return
        self._tasks_since_rotation = 0
        # Grow pool if below target; otherwise just pick from existing.
        if len(VAmPIUser._identity_pool) < USER_POOL_SIZE:
            ident = self._register_identity()
            if ident:
                VAmPIUser._identity_pool.append(ident)
                self._activate(ident)
                return
        self._activate_random_pool_identity()

    @task(4)
    def list_users(self):
        self._maybe_rotate()
        self.client.get("/vampi/users/v1")

    @task(4)
    def list_books(self):
        self._maybe_rotate()
        self.client.get("/vampi/books/v1")

    @task(3)
    def create_book(self):
        self._maybe_rotate()
        self.client.post("/vampi/books/v1",
                         json={"book_title": uid(), "secret": uid()},
                         headers=self.auth)

    @task(2)
    def reauth(self):
        # Re-login the current identity. Mirrors a real user whose token
        # expired and who logs back in. Keeps /login traffic in the mix.
        resp = self.client.post("/vampi/users/v1/login",
                                name="/vampi/users/v1/login",
                                json={"username": self.username, "password": self.password})
        if resp.status_code == 200:
            token = resp.json().get("auth_token")
            if token:
                self.auth = {"Authorization": f"Bearer {token}"}

    @task(2)
    def get_book_by_title(self):
        self._maybe_rotate()
        # VAmPI does not implement DELETE on /books/v1/<title> (returns 405).
        # GET still exercises the path-parameter route surface for Noname.
        with self.client.get(f"/vampi/books/v1/{uid()}",
                             name="/vampi/books/v1/{title}",
                             headers=self.auth,
                             catch_response=True) as r:
            if r.status_code in (200, 401, 404):
                r.success()


class DVGAUser(FastHttpUser):
    """Hits DVGA GraphQL endpoint via NGINX. No auth required."""

    host = NGINX_BASE
    weight = 2
    wait_time = between(0.5, 2)

    @task(4)
    def query_pastes(self):
        self.client.post("/dvga/graphql",
                         json=gql("{ pastes { title content } }"))

    @task(3)
    def query_users(self):
        self.client.post("/dvga/graphql",
                         json=gql("{ users { username } }"))

    @task(3)
    def query_health(self):
        self.client.post("/dvga/graphql",
                         json=gql("{ systemHealth }"))

    @task(3)
    def create_paste(self):
        self.client.post("/dvga/graphql", json=gql(
            'mutation { createPaste(title:"lab", content:"' + uid() + '", public:true)'
            ' { paste { title } } }'
        ))

    @task(1)
    def introspect(self):
        # Intentional introspection — Noname learns to detect this pattern
        self.client.post("/dvga/graphql",
                         json=gql("{ __schema { types { name } } }"))


class CrAPIUser(FastHttpUser):
    """crAPI via Kong. Pools authenticated identities across the run."""

    host = KONG_BASE
    weight = 1
    wait_time = between(1, 3)

    _identity_pool = []

    def on_start(self):
        for _ in range(USER_POOL_SEED_PER_INSTANCE):
            if len(CrAPIUser._identity_pool) >= USER_POOL_SIZE:
                break
            ident = self._register_identity()
            if ident:
                CrAPIUser._identity_pool.append(ident)

        self._tasks_since_rotation = 0
        self._activate_random_pool_identity()

    def _register_identity(self):
        suffix = uid()
        email = f"{suffix}@lab.test"
        password = "LabPass123!"
        with self.client.post("/crapi/identity/api/auth/signup",
                              json={
                                  "name": f"Lab {suffix}",
                                  "email": email,
                                  "number": str(random.randint(5550000000, 5559999999)),
                                  "password": password,
                              },
                              name="/crapi/identity/api/auth/signup",
                              catch_response=True) as r:
            # 409 = email already registered (rare with uid())
            if r.status_code in (200, 201, 409):
                r.success()
        resp = self.client.post("/crapi/identity/api/auth/login",
                                name="/crapi/identity/api/auth/login",
                                json={"email": email, "password": password})
        if resp.status_code != 200:
            return None
        token = resp.json().get("token")
        if not token:
            return None
        return {
            "email": email,
            "password": password,
            "token": token,
            "auth": {"Authorization": f"Bearer {token}"},
        }

    def _activate(self, ident):
        self.email = ident["email"]
        self.password = ident["password"]
        self.auth = ident["auth"]

    def _activate_random_pool_identity(self):
        if CrAPIUser._identity_pool:
            self._activate(random.choice(CrAPIUser._identity_pool))
        else:
            self.email = f"{uid()}@lab.test"
            self.password = "LabPass123!"
            self.auth = {}

    def _maybe_rotate(self):
        self._tasks_since_rotation += 1
        if self._tasks_since_rotation < IDENTITY_ROTATION_INTERVAL:
            return
        self._tasks_since_rotation = 0
        if len(CrAPIUser._identity_pool) < USER_POOL_SIZE:
            ident = self._register_identity()
            if ident:
                CrAPIUser._identity_pool.append(ident)
                self._activate(ident)
                return
        self._activate_random_pool_identity()

    @task(3)
    def reauth(self):
        # Re-login current identity (keeps /login traffic visible).
        resp = self.client.post("/crapi/identity/api/auth/login",
                                name="/crapi/identity/api/auth/login",
                                json={"email": self.email, "password": self.password})
        if resp.status_code == 200:
            token = resp.json().get("token")
            if token:
                self.auth = {"Authorization": f"Bearer {token}"}

    @task(3)
    def dashboard(self):
        self._maybe_rotate()
        self.client.get("/crapi/identity/api/v2/user/dashboard",
                        headers=self.auth)

    @task(3)
    def shop_products(self):
        self._maybe_rotate()
        self.client.get("/crapi/workshop/api/shop/products",
                        headers=self.auth)

    @task(2)
    def place_order(self):
        self._maybe_rotate()
        self.client.post("/crapi/workshop/api/shop/orders",
                         json={"product_id": 1, "quantity": 1},
                         headers=self.auth)

    @task(2)
    def community_posts(self):
        self._maybe_rotate()
        self.client.get("/crapi/community/api/v2/community/posts/recent",
                        headers=self.auth)


_JUICESHOP_OK = (200, 201, 204, 304, 400, 401, 403, 404, 409, 500)
_JUICESHOP_SEARCH_TERMS = ("apple", "juice", "lemon", "banana", "eggfruit", "raspberry", "melon")


class JuiceShopUser(FastHttpUser):
    """OWASP Juice Shop via Anypoint Flex Gateway proxy /shop/*. Maintains an
    authenticated-identity pool so Noname sees a diverse set of users on
    Juice Shop endpoints that are user-context-aware (basket, feedback).
    Concrete subclass `_JuiceShopUser` only registers when MULE_ALB_DNS is set.
    """

    abstract = True
    weight = 2
    wait_time = between(0.5, 2)

    _identity_pool = []

    def on_start(self):
        for _ in range(USER_POOL_SEED_PER_INSTANCE):
            if len(JuiceShopUser._identity_pool) >= USER_POOL_SIZE:
                break
            ident = self._register_identity()
            if ident:
                JuiceShopUser._identity_pool.append(ident)

        self._tasks_since_rotation = 0
        self._activate_random_pool_identity()

    def _register_identity(self):
        email = f"shop_{uid()}@lab.test"
        password = "P@ssw0rd1!"
        with self.client.post("/shop/api/Users",
                              json={
                                  "email": email,
                                  "password": password,
                                  "passwordRepeat": password,
                                  "securityQuestion": {"id": 1},
                                  "securityAnswer": "lab",
                              },
                              name="/shop/api/Users",
                              catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()
            if r.status_code not in (200, 201):
                # Registration failed (validation, duplicate, etc.) — abort.
                return None
        with self.client.post("/shop/rest/user/login",
                              json={"email": email, "password": password},
                              name="/shop/rest/user/login",
                              catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()
            if r.status_code != 200:
                return None
            try:
                token = (r.json() or {}).get("authentication", {}).get("token")
            except Exception:
                return None
        if not token:
            return None
        return {
            "email": email,
            "password": password,
            "token": token,
            "auth": {"Authorization": f"Bearer {token}"},
        }

    def _activate(self, ident):
        self.email = ident["email"]
        self.password = ident["password"]
        self.auth = ident["auth"]

    def _activate_random_pool_identity(self):
        if JuiceShopUser._identity_pool:
            self._activate(random.choice(JuiceShopUser._identity_pool))
        else:
            self.email = f"shop_{uid()}@lab.test"
            self.password = "P@ssw0rd1!"
            self.auth = {}

    def _maybe_rotate(self):
        self._tasks_since_rotation += 1
        if self._tasks_since_rotation < IDENTITY_ROTATION_INTERVAL:
            return
        self._tasks_since_rotation = 0
        if len(JuiceShopUser._identity_pool) < USER_POOL_SIZE:
            ident = self._register_identity()
            if ident:
                JuiceShopUser._identity_pool.append(ident)
                self._activate(ident)
                return
        self._activate_random_pool_identity()

    @task(4)
    def index(self):
        self._maybe_rotate()
        with self.client.get("/shop/", catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(3)
    def app_version(self):
        with self.client.get("/shop/rest/admin/application-version", catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(3)
    def app_config(self):
        with self.client.get("/shop/rest/admin/application-configuration", catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(5)
    def list_products(self):
        with self.client.get("/shop/api/Products", catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(5)
    def get_product(self):
        pid = random.randint(1, 50)
        with self.client.get(f"/shop/api/Products/{pid}",
                             name="/shop/api/Products/{id}",
                             catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(4)
    def search_products(self):
        term = random.choice(_JUICESHOP_SEARCH_TERMS)
        with self.client.get(f"/shop/rest/products/search?q={term}",
                             name="/shop/rest/products/search",
                             catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(3)
    def list_feedbacks(self):
        with self.client.get("/shop/api/Feedbacks", catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(2)
    def post_feedback(self):
        # Authenticated feedback submission — Noname will associate the
        # comment with the active pool identity.
        self._maybe_rotate()
        with self.client.post("/shop/api/Feedbacks",
                              json={
                                  "comment": f"lab feedback {uid()}",
                                  "rating": random.randint(1, 5),
                                  "captchaId": 1,
                                  "captcha": "wrong",
                              },
                              headers=self.auth,
                              catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(3)
    def login_bad(self):
        # Random failed login — mimics credential-stuffing / typo background.
        with self.client.post("/shop/rest/user/login",
                              json={
                                  "email": f"{uid()}@lab.test",
                                  "password": "wrong",
                              },
                              name="/shop/rest/user/login (bad)",
                              catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(2)
    def captcha(self):
        with self.client.get("/shop/rest/captcha/", catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(2)
    def list_quantities(self):
        with self.client.get("/shop/api/Quantitys", catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(2)
    def list_challenges(self):
        with self.client.get("/shop/api/Challenges", catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(2)
    def get_basket(self):
        # Authenticated basket fetch using the active pool identity.
        self._maybe_rotate()
        bid = random.randint(1, 5)
        with self.client.get(f"/shop/rest/basket/{bid}",
                             name="/shop/rest/basket/{id}",
                             headers=self.auth,
                             catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()


if MULE_BASE:
    # Concrete subclass with host set; only registered when MULE_ALB_DNS is provided
    class _JuiceShopUser(JuiceShopUser):
        abstract = False
        host = MULE_BASE
