import importlib.util, json, os, tempfile, unittest
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("indexer", os.path.join(ROOT, "web", "indexer.py"))
ix = importlib.util.module_from_spec(spec); spec.loader.exec_module(ix)
TOKEN = "0x" + "ab" * 20
w = lambda n: hex(n)[2:].rjust(64, "0")
t = lambda a: "0x" + a[2:].rjust(64, "0")

def launch(n=10, uri=b"ipfs://x", tx="0xaa"):
    data = "0x" + w(5) + w(0xc0) + w(0xc1) + w(128) + w(len(uri)) + uri.hex().ljust(64, "0")
    return {"topics": [ix.TOPICS["launch2"], t(TOKEN), t("0x" + "11" * 20), t("0x" + "22" * 20)], "data": data, "blockNumber": hex(n), "logIndex": "0x0", "transactionHash": tx}
def trade(n=11, i=1, tx="0xbb"):
    return {"topics": [ix.TOPICS["trade"], t(TOKEN), t("0x" + "33" * 20)], "data": "0x" + w(1) + w(100) + w(200) + w(1) + w(0) + w(0), "blockNumber": hex(n), "logIndex": hex(i), "transactionHash": tx}

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
                json.dump({"pad": "0xold", "scannedTo": 5, "launches": {"a": 1}}, f)
            s = ix.load("prod")
            self.assertEqual(s["pad"], ix.INSTANCES["prod"]["pad"])
            self.assertEqual(s["launches"], {})
            self.assertEqual(s["scannedTo"], ix.INSTANCES["prod"]["start"] - 1)

    def test_load_resumes_same_pad_and_survives_a_corrupt_file(self):
        with tempfile.TemporaryDirectory() as d:
            ix.OUT = d
            p = os.path.join(d, "index-prod.json")
            with open(p, "w") as f:
                json.dump({"pad": ix.INSTANCES["prod"]["pad"].lower(), "scannedTo": 99, "launches": {}}, f)
            self.assertEqual(ix.load("prod")["scannedTo"], 99)
            with open(p, "w") as f:
                f.write("{broken")
            self.assertEqual(ix.load("prod")["scannedTo"], ix.INSTANCES["prod"]["start"] - 1)

if __name__ == "__main__":
    unittest.main()
