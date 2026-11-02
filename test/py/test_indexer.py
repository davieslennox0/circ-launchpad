import importlib.util, json, os, tempfile, unittest
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("indexer", os.path.join(ROOT, "web", "indexer.py"))
ix = importlib.util.module_from_spec(spec); spec.loader.exec_module(ix)
REAL_RPC = ix.rpc
TOKEN = "0x" + "ab" * 20
w = lambda n: hex(n)[2:].rjust(64, "0")
t = lambda a: "0x" + a[2:].rjust(64, "0")

def launch(n=10, uri=b"ipfs://x", tx="0xaa"):
    data = "0x" + w(5) + w(0xc0) + w(0xc1) + w(128) + w(len(uri)) + uri.hex().ljust(64, "0")
    return {"topics": [ix.TOPICS["launch2"], t(TOKEN), t("0x" + "11" * 20), t("0x" + "22" * 20)], "data": data, "blockNumber": hex(n), "logIndex": "0x0", "transactionHash": tx}
def trade(n=11, i=1, tx="0xbb"):
    return {"topics": [ix.TOPICS["trade"], t(TOKEN), t("0x" + "33" * 20)], "data": "0x" + w(1) + w(100) + w(200) + w(1) + w(0) + w(0), "blockNumber": hex(n), "logIndex": hex(i), "transactionHash": tx}

class Prices(unittest.TestCase):
    def test_curve_price_uses_each_quote_decimals(self):
        self.assertAlmostEqual(ix.curve_price(2 * 10**18, 10**27, "0x" + "e5" * 20), 2e-9)
        self.assertAlmostEqual(ix.curve_price(2 * 10**8, 10**27, ix.BEM), 2e-9)

    def test_pool_price_follows_currency_order(self):
        sq = int(2 ** 96 * (2e-9 ** 0.5))
        self.assertAlmostEqual(ix.pool_price(sq, "0x" + "11" * 20, "0x" + "e5" * 20) / 2e-9, 1, 6)  # token is currency0
        self.assertAlmostEqual(ix.pool_price(int(2 ** 96 / (2e-9 ** 0.5)), "0x" + "f1" * 20, "0x" + "e5" * 20) / 2e-9, 1, 6)  # token is currency1

    def test_repeated_window_adds_no_point(self):
        L = {}
        for _ in range(2):
            ix.add_point(L, 10, 1, 100, 1.0, now=200)
            ix.add_point(L, 11, 0, 150, 2.0, now=200)
        self.assertEqual(L["prices"], [[100, 1.0], [150, 2.0]])

    def test_keeps_one_anchor_older_than_the_window(self):
        L = {}
        for i, ts in enumerate([10, 20, 30, 90000]):
            ix.add_point(L, i, 0, ts, float(i), now=90000)
        self.assertEqual(L["prices"], [[30, 2.0], [90000, 3.0]])

    def test_migration_rescans_and_keeps_launches(self):
        s = {"startBlock": 5, "scannedTo": 99, "poolScannedTo": 99, "launches": {TOKEN: {"prices": [[1, 1.0]], "lastPt": [9, 9], "startPt": True}}}
        ix.migrate(s)
        self.assertEqual((s["scannedTo"], s["v"], "poolScannedTo" in s), (4, ix.INDEX_VERSION, False))
        self.assertEqual(s["launches"][TOKEN]["prices"], [])


class Indexer(unittest.TestCase):
    def setUp(self):
        self.calls = []
        ix.rpc = lambda m, p: {"timestamp": "0x64"} if m == "eth_getBlockByNumber" else None
        ix._ts.clear()
        self.s = {"launches": {}}

    def test_launch_decodes_image_uri(self):
        ix.apply(self.s, launch())
        L = self.s["launches"][TOKEN]
        self.assertEqual(L["imageURI"], "ipfs://x")
        self.assertEqual(L["circuitId"], 5)

    def test_reprocessing_a_window_changes_nothing(self):
        # M2: a 429 halfway through a window means the whole window is scanned again.
        for lg in (launch(), trade(), trade(i=2)):
            ix.apply(self.s, lg)
        before = json.dumps(self.s, sort_keys=True)
        for lg in (launch(), trade(), trade(i=2)):
            ix.apply(self.s, lg)
        self.assertEqual(json.dumps(self.s, sort_keys=True), before)
        self.assertEqual(len(self.s["launches"][TOKEN]["trades"]), 2)

    def test_failure_mid_window_then_retry_has_no_duplicates(self):
        ix.apply(self.s, launch())
        ix.apply(self.s, trade(n=11))
        real = ix.block_ts
        def boom(n): raise RuntimeError("429")
        ix.block_ts = boom
        with self.assertRaises(RuntimeError):
            ix.apply(self.s, trade(n=12, i=3, tx="0xcc"))
        ix.block_ts = real
        for lg in (launch(), trade(n=11), trade(n=12, i=3, tx="0xcc")):
            ix.apply(self.s, lg)
        self.assertEqual([x["tx"] for x in self.s["launches"][TOKEN]["trades"]], ["0xbb", "0xcc"])

    def test_oversized_image_uri_is_dropped(self):
        ix.apply(self.s, launch(uri=b"x" * 300))
        self.assertEqual(self.s["launches"][TOKEN]["imageURI"], "")

    def test_load_starts_fresh_when_the_pad_changed(self):
        # M3: this used to return None and kill the instance.
        with tempfile.TemporaryDirectory() as d:
            ix.OUT = d
            with open(os.path.join(d, "index-prod.json"), "w") as f:
                json.dump({"v": ix.INDEX_VERSION, "pad": "0xold", "scannedTo": 5, "launches": {"a": 1}}, f)
            s = ix.load("prod")
            self.assertEqual(s["pad"], ix.INSTANCES["prod"]["pad"])
            self.assertEqual(s["launches"], {})
            self.assertEqual(s["scannedTo"], ix.INSTANCES["prod"]["start"] - 1)

    def test_load_resumes_same_pad_and_survives_a_corrupt_file(self):
        with tempfile.TemporaryDirectory() as d:
            ix.OUT = d
            p = os.path.join(d, "index-prod.json")
            with open(p, "w") as f:
                json.dump({"v": ix.INDEX_VERSION, "pad": ix.INSTANCES["prod"]["pad"].lower(), "scannedTo": 99, "launches": {}}, f)
            self.assertEqual(ix.load("prod")["scannedTo"], 99)
            with open(p, "w") as f:
                f.write("{broken")
            self.assertEqual(ix.load("prod")["scannedTo"], ix.INSTANCES["prod"]["start"] - 1)

class PrivateRpc(unittest.TestCase):
    SECRET = "https://rpc.example/secret-token"

    def setUp(self):
        self.saved = (ix.RPCS, ix.rpc_at)
        ix.RPCS = [self.SECRET, "https://public.example"]

    def tearDown(self):
        ix.RPCS, ix.rpc_at = self.saved

    def test_falls_back_when_the_primary_refuses(self):
        seen = []
        def at(url, method, params):
            seen.append(url)
            if url == self.SECRET:
                raise RuntimeError("archive requests are not available")
            return []
        ix.rpc_at = at
        self.assertEqual(REAL_RPC("eth_getLogs", [{}]), [])
        self.assertEqual(seen, ix.RPCS)

    def test_an_error_never_shows_the_url(self):
        def at(url, method, params):
            raise RuntimeError(f"failed for {url}")
        ix.rpc_at = at
        with self.assertRaises(RuntimeError) as c:
            REAL_RPC("eth_blockNumber", [])
        self.assertNotIn("secret-token", str(c.exception))
        self.assertNotIn("secret-token", ix.redact(f"x {self.SECRET} y"))


if __name__ == "__main__":
    unittest.main()
