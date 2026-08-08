"""Offline tests for function_app.py.

Stubs azure.functions and httpx, so this runs with a bare interpreter and no
installed dependencies:

    python3 tests/test_function_app.py

Exits non-zero on the first failing expectation. Covers the two things that are
easy to get quietly wrong -- whole-word vendor matching and internal-address
classification -- plus the end-to-end shape of the response the Logic App parses.
"""
import asyncio, json, os, pathlib, sys, types

# --- stub azure.functions -------------------------------------------------- #
az = types.ModuleType("azure"); azf = types.ModuleType("azure.functions")
class _AuthLevel: FUNCTION = "function"
class _FunctionApp:
    def __init__(self, **kw): pass
    def function_name(self, **kw): return lambda f: f
    def route(self, **kw): return lambda f: f
class _HttpRequest:
    def __init__(self, body): self._b = body
    def get_json(self):
        if self._b is None: raise ValueError("no json")
        return self._b
class _HttpResponse:
    def __init__(self, body, status_code=200, mimetype=None):
        self.body, self.status_code = body, status_code
azf.AuthLevel = _AuthLevel; azf.FunctionApp = _FunctionApp
azf.HttpRequest = _HttpRequest; azf.HttpResponse = _HttpResponse
az.functions = azf
sys.modules["azure"] = az; sys.modules["azure.functions"] = azf

# --- stub httpx ------------------------------------------------------------ #
hx = types.ModuleType("httpx")
class _HTTPError(Exception): pass
class _Response:
    def __init__(self, status_code, payload=None, headers=None, text=""):
        self.status_code, self._p = status_code, payload
        self.headers, self.text = headers or {}, text
    def json(self):
        if self._p is None: raise ValueError("bad json")
        return self._p
class _Limits:
    def __init__(self, **kw): pass
FAKE_DB = {}
class _AsyncClient:
    def __init__(self, **kw): pass
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def get(self, url, params=None, headers=None):
        ip = params["ipAddress"]
        if ip == "45.33.32.156":
            return _Response(500, text="boom")
        return _Response(200, {"data": FAKE_DB.get(ip, {"ipAddress": ip, "isp": "Some ISP",
                                                        "domain": "example.com", "hostnames": [],
                                                        "abuseConfidenceScore": 0})})
hx.HTTPError = _HTTPError; hx.Response = _Response
hx.Limits = _Limits; hx.AsyncClient = _AsyncClient
sys.modules["httpx"] = hx

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
os.environ["ABUSEIPDB_API_KEY"] = "test-key"
import function_app as fa

ok = True
def check(label, got, want):
    global ok
    if got != want:
        ok = False
        print(f"FAIL {label}: got {got!r}, want {want!r}")
    else:
        print(f"ok   {label}")

# --- normalisation & keyword matching -------------------------------------- #
check("normalise SITA.aero", fa._normalise("SITA.aero"), "sita aero")
check("normalise Lufthansa Systems GmbH", fa._normalise("Lufthansa Systems GmbH"), "lufthansa systems gmbh")

kws = fa._compile_keywords(["lufthansa", "lido", "sita aero"])
def vendor(isp="", domain="", hostnames=()):
    hay = fa._vendor_haystack({"isp": isp, "domain": domain, "hostnames": list(hostnames)})
    return next((lbl for lbl, pat in kws if pat.search(hay)), None)

check("isp Lufthansa Systems",  vendor(isp="Lufthansa Systems GmbH"), "lufthansa")
check("domain sita.aero",       vendor(domain="sita.aero"), "sita aero")
check("hostname lido.example",  vendor(hostnames=["srv1.lido.example.com"]), "lido")
check("no match on Deutsche",   vendor(isp="Deutsche Telekom AG", domain="t-online.de"), None)
# whole-word: the substring traps
check("no match 'lidonet'",     vendor(isp="Lidonet Communications"), None)
check("no match 'solido'",      vendor(domain="solido.com"), None)
check("no match 'sitawi'",      vendor(isp="Sitawi Networks"), None)
check("match sita-aero hyphen", vendor(domain="sita-aero.net"), "sita aero")

# --- entry parsing --------------------------------------------------------- #
check("parse plain ip",   fa._parse_entry("8.8.8.8")[1], "ip")
check("parse /32 as ip",  fa._parse_entry("8.8.8.8/32")[1], "ip")
check("parse /24 as cidr", fa._parse_entry("45.33.0.0/16")[1], "cidr")
check("parse junk",       fa._parse_entry("<html>")[1], "invalid")
check("parse v6",         fa._parse_entry("2001:db8::1")[1], "ip")

# --- internal classification ----------------------------------------------- #
def internal(entry, extra=()):
    obj, kind = fa._parse_entry(entry)
    return fa._is_internal(obj, fa._parse_networks(list(extra)))

for private in ["10.1.2.3", "192.168.1.5", "172.16.0.1", "172.31.255.254", "127.0.0.1",
                "169.254.1.1", "fd00::1", "::1", "10.0.0.0/8"]:
    check(f"internal {private}", internal(private), True)
# the classic prefix-string false positives that CIDR maths gets right
for public in ["1.10.0.1", "172.15.0.1", "172.32.0.1", "193.168.1.1", "8.8.8.8", "2606:4700:4700::1111"]:
    check(f"public {public}", internal(public), False)
check("extra cidr hit",  internal("45.33.32.156", ["45.33.0.0/16"]), True)
check("extra cidr miss", internal("45.34.0.1", ["45.33.0.0/16"]), False)
check("extra cidr net",  internal("45.33.0.0/24", ["45.33.0.0/16"]), True)
# Python is_private spans the whole IANA special-purpose set, not just RFC1918
check("TEST-NET-3 is private", internal("203.0.113.7"), True)
check("benchmark 198.18 private", internal("198.18.0.1"), True)

# --- end-to-end handler ---------------------------------------------------- #
FAKE_DB.update({
    "1.2.3.4":  {"ipAddress": "1.2.3.4", "isp": "Lufthansa Systems GmbH", "domain": "lhsystems.com",
                 "hostnames": [], "abuseConfidenceScore": 12, "totalReports": 3,
                 "countryCode": "DE", "usageType": "Data Center/Web Hosting/Transit"},
    "5.6.7.8":  {"ipAddress": "5.6.7.8", "isp": "SITA", "domain": "sita.aero",
                 "hostnames": ["gw.sita.aero"], "abuseConfidenceScore": 0, "totalReports": 0,
                 "countryCode": "CH", "usageType": "Organization"},
    "9.9.9.9":  {"ipAddress": "9.9.9.9", "isp": "Quad9", "domain": "quad9.net",
                 "hostnames": [], "abuseConfidenceScore": 0},
})
req = _HttpRequest({
    "shard": 1,
    "ips": ["1.2.3.4", "5.6.7.8", "9.9.9.9", "10.0.0.5", "45.33.0.0/16",
            "not-an-ip", "45.33.32.156", "  ", "192.168.4.4/32"],
    "vendorKeywords": ["lufthansa", "lido", "sita aero"],
    "extraInternalCidrs": [],
    "maxAgeInDays": 90,
    "concurrency": 10,
})
resp = asyncio.run(fa.enrich_ips(req))
out = json.loads(resp.body)

c = out["counts"]
check("resp status", resp.status_code, 200)
check("requested", c["requested"], 9)
check("internal count", c["internal"], 2)          # 10.0.0.5 + 192.168.4.4/32
check("vendor count", c["vendor"], 2)              # lufthansa + sita aero
check("findings", c["findings"], 4)
check("skipped (public cidr)", c["skipped"], 1)    # 45.33.0.0/16
check("invalid", c["invalid"], 1)                  # not-an-ip
check("errors", c["errors"], 1)                    # 45.33.32.156 -> HTTP 500
check("checked", c["checked"], 3)                  # 4 public singles, 1 errored
check("quad9 not a finding", [r["ip"] for r in out["results"] if r["ip"] == "9.9.9.9"], [])
internal_rows = [r for r in out["results"] if r["category"] == "internal"]
check("internal score is null", [r["abuseConfidenceScore"] for r in internal_rows], [None, None])
check("internal vendor label", sorted({r["vendor"] for r in internal_rows}), ["internal"])
vendor_rows = {r["ip"]: r for r in out["results"] if r["category"] == "vendor"}
check("lufthansa row", (vendor_rows["1.2.3.4"]["vendor"], vendor_rows["1.2.3.4"]["abuseConfidenceScore"]),
      ("lufthansa", 12))
check("sita row", (vendor_rows["5.6.7.8"]["vendor"], vendor_rows["5.6.7.8"]["abuseConfidenceScore"]),
      ("sita aero", 0))

# empty shard (the Logic App sends json('[]') when there are fewer than 5 chunks)
empty = json.loads(asyncio.run(fa.enrich_ips(_HttpRequest({"shard": 5, "ips": []}))).body)
check("empty shard results", empty["results"], [])
check("empty shard counts", empty["counts"]["findings"], 0)

# missing key -> 500, not a silent empty result
os.environ["ABUSEIPDB_API_KEY"] = ""
check("no api key -> 500", asyncio.run(fa.enrich_ips(_HttpRequest({"ips": []}))).status_code, 500)
os.environ["ABUSEIPDB_API_KEY"] = "test-key"
check("bad body -> 400", asyncio.run(fa.enrich_ips(_HttpRequest(None))).status_code, 400)
check("ips not array -> 400", asyncio.run(fa.enrich_ips(_HttpRequest({"ips": "x"}))).status_code, 400)

print("\nALL PASS" if ok else "\nFAILURES ABOVE")
sys.exit(0 if ok else 1)
