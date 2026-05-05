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
    """Hits VAmPI REST API via NGINX. Registers a unique user on start."""

    host = NGINX_BASE
    weight = 2
    wait_time = between(0.5, 2)

    # Class-level so we only hit /createdb once per locust process even if
    # many VAmPIUser instances spawn concurrently.
    _db_initialized = False

    def on_start(self):
        self.username = f"user_{uid()}"
        self.password = "LabPass123!"
        self.auth = {}

        if not VAmPIUser._db_initialized:
            # VAmPI ships with empty SQLite — /createdb seeds the users/books tables.
            # Without this, every other call returns a 500 ("no such table: users").
            with self.client.get("/vampi/createdb",
                                 name="/vampi/createdb (init)",
                                 catch_response=True) as r:
                if r.status_code in (200, 404):
                    r.success()
            VAmPIUser._db_initialized = True

        self.client.post("/vampi/users/v1/register", json={
            "username": self.username,
            "password": self.password,
            "email": f"{self.username}@lab.test",
        })

        resp = self.client.post("/vampi/users/v1/login", json={
            "username": self.username,
            "password": self.password,
        })
        # VAmPI returns auth_token at the top level (not nested under "data").
        if resp.status_code == 200:
            token = resp.json().get("auth_token")
            if token:
                self.auth = {"Authorization": f"Bearer {token}"}

    @task(4)
    def list_users(self):
        self.client.get("/vampi/users/v1")

    @task(4)
    def list_books(self):
        self.client.get("/vampi/books/v1")

    @task(3)
    def create_book(self):
        self.client.post("/vampi/books/v1",
                         json={"book_title": uid(), "secret": uid()},
                         headers=self.auth)

    @task(2)
    def reauth(self):
        resp = self.client.post("/vampi/users/v1/login", json={
            "username": self.username,
            "password": self.password,
        })
        if resp.status_code == 200:
            token = resp.json().get("auth_token")
            if token:
                self.auth = {"Authorization": f"Bearer {token}"}

    @task(2)
    def get_book_by_title(self):
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
    """Hits crAPI multi-service backend via Kong. Registers a unique account on start."""

    host = KONG_BASE
    weight = 1
    wait_time = between(1, 3)

    def on_start(self):
        suffix = uid()
        self.email = f"{suffix}@lab.test"
        self.password = "LabPass123!"
        self.auth = {}

        self.client.post("/crapi/identity/api/auth/signup", json={
            "name": f"Lab {suffix}",
            "email": self.email,
            "number": str(random.randint(5550000000, 5559999999)),
            "password": self.password,
        })

        resp = self.client.post("/crapi/identity/api/auth/login", json={
            "email": self.email,
            "password": self.password,
        })
        if resp.status_code == 200:
            token = resp.json().get("token")
            if token:
                self.auth = {"Authorization": f"Bearer {token}"}

    @task(3)
    def reauth(self):
        resp = self.client.post("/crapi/identity/api/auth/login", json={
            "email": self.email,
            "password": self.password,
        })
        if resp.status_code == 200:
            token = resp.json().get("token")
            if token:
                self.auth = {"Authorization": f"Bearer {token}"}

    @task(3)
    def dashboard(self):
        self.client.get("/crapi/identity/api/v2/user/dashboard",
                        headers=self.auth)

    @task(3)
    def shop_products(self):
        self.client.get("/crapi/workshop/api/shop/products",
                        headers=self.auth)

    @task(2)
    def place_order(self):
        self.client.post("/crapi/workshop/api/shop/orders",
                         json={"product_id": 1, "quantity": 1},
                         headers=self.auth)

    @task(2)
    def community_posts(self):
        self.client.get("/crapi/community/api/v2/community/posts/recent",
                        headers=self.auth)


_JUICESHOP_OK = (200, 201, 204, 304, 400, 401, 403, 404, 409, 500)
_JUICESHOP_SEARCH_TERMS = ("apple", "juice", "lemon", "banana", "eggfruit", "raspberry", "melon")


class JuiceShopUser(FastHttpUser):
    """Hits OWASP Juice Shop via the Anypoint Flex Gateway proxy at /shop/*.
    Mix of unauthenticated SPA, REST, search, login/register, and basket calls
    so Noname sees a wide API surface to learn from.
    """

    abstract = True
    weight = 2
    wait_time = between(0.5, 2)

    @task(4)
    def index(self):
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
        with self.client.post("/shop/api/Feedbacks",
                              json={
                                  "comment": f"lab feedback {uid()}",
                                  "rating": random.randint(1, 5),
                                  "captchaId": 1,
                                  "captcha": "wrong",
                              },
                              catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(3)
    def login_bad(self):
        with self.client.post("/shop/rest/user/login",
                              json={
                                  "email": f"{uid()}@lab.test",
                                  "password": "wrong",
                              },
                              catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()

    @task(2)
    def register(self):
        with self.client.post("/shop/api/Users",
                              json={
                                  "email": f"{uid()}@lab.test",
                                  "password": "P@ssw0rd1!",
                                  "passwordRepeat": "P@ssw0rd1!",
                                  "securityQuestion": {"id": 1},
                                  "securityAnswer": "lab",
                              },
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
        bid = random.randint(1, 5)
        with self.client.get(f"/shop/rest/basket/{bid}",
                             name="/shop/rest/basket/{id}",
                             catch_response=True) as r:
            if r.status_code in _JUICESHOP_OK:
                r.success()


if MULE_BASE:
    # Concrete subclass with host set; only registered when MULE_ALB_DNS is provided
    class _JuiceShopUser(JuiceShopUser):
        abstract = False
        host = MULE_BASE
