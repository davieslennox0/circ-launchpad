// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurvePad} from "../../src/CurvePad.sol";
import {Addresses} from "../../script/Addresses.sol";

interface INandoutCircuits {
    function transistors() external view returns (address);
    function TAPEOUT_FEE() external view returns (uint256);
    function nextId() external view returns (uint256);
    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function ownerOf(uint256) external view returns (address);
    function circuitInfo(uint256) external view returns (uint32, uint32, uint32, uint32);
    function transferFrom(address, address, uint256) external;
}

interface INandoutTransistors {
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function supplyCap() external view returns (uint256);
    function minted() external view returns (uint256);
    function creator() external view returns (address);
    function owed(address) external view returns (uint256);
    function balanceOf(address, uint256) external view returns (uint256);
}

/// @notice Frontend recon for the pitchook.xyz "Pick a Nand" flow, against the LIVE production CurvePad on a fork:
/// a brand-new Nand (mint 1 NAND transistor + tape out a 1-gate netlist) passes createLaunch and can be bought, and the
/// "already launched" signal the frontend uses (LaunchCreated with circuitNft indexed) is present.
contract NandoutMintForkTest is Test {
    address constant PROD_PAD = 0x45E97E81d50D0c77170D9cb622f9d255768E4827;
    uint256 constant NAND = 0;
    bytes constant ONE_NAND = hex"00000002000003"; // NAND(in0, in1): nIn=2, nOut=1

    INandoutCircuits nand = INandoutCircuits(Addresses.NANDOUT);
    CurvePad pad = CurvePad(payable(PROD_PAD));

    function setUp() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")));
    }

    function _mintNand(address who) internal returns (uint256 id) {
        INandoutTransistors t = INandoutTransistors(nand.transistors());
        uint256 cost = t.mintPrice() + t.protocolFee(); // 1 transistor + per-mint protocol fee
        vm.startPrank(who);
        t.mint{value: cost}(NAND, 1);
        assertEq(t.balanceOf(who, NAND), 1, "1 NAND transistor minted");
        id = nand.tapeout{value: nand.TAPEOUT_FEE()}(ONE_NAND, 2, 1);
        vm.stopPrank();
        assertEq(t.balanceOf(who, NAND), 0, "transistor burned by tapeout");
    }

    function test_fork_freshNand_mint_launch_buy_onProdPad() public {
        INandoutTransistors t = INandoutTransistors(nand.transistors());
        address creator = t.creator();
        uint256 owedBefore = t.owed(creator);
        uint256 idBefore = nand.nextId();
        uint256 totalCost = t.mintPrice() + t.protocolFee() + nand.TAPEOUT_FEE();
        emit log_named_uint("new Nand total cost (wei)", totalCost);

        address user = makeAddr("freshNandUser");
        vm.deal(user, 1 ether);
        uint256 balBefore = user.balance;
        uint256 id = _mintNand(user);

        assertEq(id, idBefore + 1, "next sequential id");
        assertEq(nand.ownerOf(id), user, "minted to the caller (any external site can call)");
        assertEq(balBefore - user.balance, totalCost, "exact mint cost, no refund held");
        assertEq(t.owed(creator) - owedBefore, t.mintPrice(), "mint price accrues to the Nandout creator wallet");
        (,,, uint32 gates) = nand.circuitInfo(id);
        assertEq(gates, 1, "one gate");

        // Launch on the production CurvePad, recording the LaunchCreated log the frontend uses for detection.
        vm.recordLogs();
        vm.prank(user);
        address token = pad.createLaunch(Addresses.NANDOUT, id, "Fresh Nand", "FNAND", Addresses.WOKB, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == PROD_PAD && logs[i].topics[0] == CurvePad.LaunchCreated.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), token);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), Addresses.NANDOUT, "circuitNft is indexed");
                (uint256 cid,, address who) = abi.decode(logs[i].data, (uint256, address, address));
                assertEq(cid, id);
                assertEq(who, user);
                found = true;
            }
        }
        assertTrue(found, "LaunchCreated emitted");

        // Buy after the guard.
        vm.roll(block.number + pad.GUARD_BLOCKS());
        vm.prank(user);
        uint256 out = pad.buyWithOKB{value: 0.01 ether}(token, 0, block.timestamp + 600);
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(user), out);

        // Same holder, same Nand, same name+ticker: CREATE2 address collides -> reverts.
        vm.prank(user);
        vm.expectRevert();
        pad.createLaunch(Addresses.NANDOUT, id, "Fresh Nand", "FNAND", Addresses.WOKB, 0, 0);
        // ...but a different name/ticker changes the init code hash, so the SAME holder can launch again from the same
        // Nand. CurvePad has no per-circuit uniqueness: "already launched" is a frontend rule (LaunchCreated by Nand).
        vm.prank(user);
        address again = pad.createLaunch(Addresses.NANDOUT, id, "Again", "AGAIN", Addresses.WOKB, 0, 0);
        assertTrue(again != token, "second launch from the same Nand by the same holder succeeds on chain");
    }

    /// @dev Documents a gap the frontend must cover: CurvePad has no per-circuit uniqueness. After a transfer, the new
    /// holder gets a different CREATE2 salt and CAN launch a second token from the same Nand (same Container).
    function test_fork_transferredNand_canBeLaunchedAgain_byNewHolder() public {
        address a = makeAddr("holderA");
        address b = makeAddr("holderB");
        vm.deal(a, 1 ether);
        uint256 id = _mintNand(a);
        vm.prank(a);
        address t1 = pad.createLaunch(Addresses.NANDOUT, id, "One", "ONE", Addresses.WOKB, 0, 0);
        vm.prank(a);
        nand.transferFrom(a, b, id);
        vm.prank(b);
        address t2 = pad.createLaunch(Addresses.NANDOUT, id, "Two", "TWO", Addresses.WOKB, 0, 0);
        assertTrue(t1 != t2, "second launch from the same Nand succeeds on chain");
        (,,,,, address c1,,,,) = pad.curves(t1);
        (,,,,, address c2,,,,) = pad.curves(t2);
        assertEq(c1, c2, "both launches pay the same Container");
    }
}
