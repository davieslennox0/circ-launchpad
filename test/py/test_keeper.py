import importlib.util, json, os, subprocess, tempfile, unittest
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.update(CIRC_PAD="0x" + "aa" * 20, KEEPER_KEYSTORE="/ks", KEEPER_PASSWORD_FILE="/pw")
spec = importlib.util.spec_from_file_location("keeper", os.path.join(ROOT, "script", "keeper", "keeper.py"))
kp = importlib.util.module_from_spec(spec); spec.loader.exec_module(kp)
TOKEN = "0x" + "bb" * 20
status_word = lambda st: "0x" + "0" * 64 * 9 + hex(st)[2:].rjust(64, "0")

class Chain:
    def __init__(self, head=10, logs=None, statuses=None):
        self.head, self.logs, self.statuses, self.ranges = head, logs or [], statuses or [], []
    def __call__(self, method, params):
        if method == "eth_blockNumber": return hex(self.head)
        if method == "eth_getLogs":
            self.ranges.append((int(params[0]["fromBlock"], 16), int(params[0]["toBlock"], 16)))
            return self.logs if self.ranges[-1][0] <= 3 <= self.ranges[-1][1] else []
        if method == "eth_call": return status_word(self.statuses.pop(0))
        raise AssertionError(method)

class Keeper(unittest.TestCase):
    def setUp(self):
        d = tempfile.mkdtemp()
        kp.STATE_FILE = os.path.join(d, "state.json")
        self.sent = []
        kp.graduate = lambda t: self.sent.append(t)
        kp.log = lambda m: None
        self.log = {"topics": [kp.TOPIC_COMPLETED, "0x" + TOKEN[2:].rjust(64, "0")], "blockNumber": "0x3"}

    def test_selectors_match_the_contract(self):
        for sig, want in (("curves(address)", kp.SEL_CURVES),):
            got = subprocess.run(["cast", "sig", sig], capture_output=True, text=True)
            if got.returncode == 0:
                self.assertEqual(got.stdout.strip(), want)
        got = subprocess.run(["cast", "keccak", "CurveCompleted(address)"], capture_output=True, text=True)
        if got.returncode == 0:
            self.assertEqual(got.stdout.strip(), kp.TOPIC_COMPLETED)

    def test_complete_curve_is_graduated_once_then_forgotten(self):
        kp.rpc = Chain(head=12, logs=[self.log], statuses=[1, 2])
        s = {"next_block": 0, "pending": []}
        kp.tick(s)
        self.assertEqual(self.sent, [TOKEN])
        self.assertEqual(s["pending"], [])
        self.assertEqual(s["next_block"], 11, "head minus confirmations, plus one")

    def test_failed_graduation_is_retried_next_tick(self):
        kp.rpc = Chain(head=12, logs=[self.log], statuses=[1, 1, 1, 2])
        s = {"next_block": 0, "pending": []}
        kp.tick(s)
        self.assertEqual(s["pending"], [TOKEN], "still pending")
        kp.tick(s)
        self.assertEqual(self.sent, [TOKEN, TOKEN])
        self.assertEqual(s["pending"], [])

    def test_already_graduated_by_someone_else_sends_nothing(self):
        kp.rpc = Chain(head=12, logs=[self.log], statuses=[2])
        s = {"next_block": 0, "pending": []}
        kp.tick(s)
        self.assertEqual(self.sent, [])

    def test_log_windows_never_exceed_the_rpc_limit(self):
        c = Chain(head=350)
        kp.rpc = c
        kp.tick({"next_block": 0, "pending": []})
        self.assertTrue(all(b - a + 1 <= 100 for a, b in c.ranges))
        self.assertEqual(c.ranges[-1][1], 348)

    def test_state_survives_a_restart(self):
        kp.rpc = Chain(head=12)
        kp.tick({"next_block": 0, "pending": []})
        self.assertEqual(kp.load_state()["next_block"], 11)

    def test_key_is_never_on_the_command_line(self):
        self.assertEqual(kp.signer_args(), ["--keystore", "/ks", "--password-file", "/pw"])
        src = open(os.path.join(ROOT, "script", "keeper", "keeper.py")).read()
        self.assertNotIn("--private-key", src)

if __name__ == "__main__":
    unittest.main()
