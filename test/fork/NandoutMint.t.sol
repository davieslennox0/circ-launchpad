// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.t.sol";
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
    function creator() external view returns (address);
    function owed(address) external view returns (uint256);
    function balanceOf(address, uint256) external view returns (uint256);
}

/// @notice The pitchook.xyz "Pick a Nand" flow on a mainnet fork, against a freshly deployed CurvePad: a brand-new Nand
/// (mint 1 NAND transistor + tape out a 1-gate netlist, as an external site would) passes createLaunch and trades, and
/// a Circuit can be launched exactly once, by anyone, ever (isLaunched / AlreadyLaunched).
contract NandoutMintForkTest is ForkBase {
    uint256 constant NAND = 0;
    bytes constant ONE_NAND = hex"00000002000003"; // NAND(in0, in1): nIn=2, nOut=1

    INandoutCircuits nandout = INandoutCircuits(Addresses.NANDOUT);

    function _mintNand(address who) internal returns (uint256 id) {
        INandoutTransistors t = INandoutTransistors(nandout.transistors());
        vm.deal(who, who.balance + 1 ether);
        vm.startPrank(who);
        t.mint{value: t.mintPrice() + t.protocolFee()}(NAND, 1);
        assertEq(t.balanceOf(who, NAND), 1, "1 NAND transistor minted");
        id = nandout.tapeout{value: nandout.TAPEOUT_FEE()}(ONE_NAND, 2, 1);
        vm.stopPrank();
        assertEq(t.balanceOf(who, NAND), 0, "transistor burned by tapeout");
    }

    function test_fork_freshNand_mint_launch_buy() public {
        INandoutTransistors t = INandoutTransistors(nandout.transistors());
        address creator_ = t.creator();
        uint256 owedBefore = t.owed(creator_);
        uint256 idBefore = nandout.nextId();
        uint256 totalCost = t.mintPrice() + t.protocolFee() + nandout.TAPEOUT_FEE();
        emit log_named_uint("new Nand total cost (wei)", totalCost);

        address user = makeAddr("freshNandUser");
        vm.deal(user, 1 ether);
        uint256 balBefore = user.balance;
        uint256 id = _mintNand(user);
        assertEq(id, idBefore + 1, "next sequential id");
        assertEq(nandout.ownerOf(id), user, "minted to the caller: any external site can call");
        assertEq(balBefore + 1 ether - user.balance, totalCost, "exact mint cost");
        assertEq(t.owed(creator_) - owedBefore, t.mintPrice(), "mint price accrues to the Nandout creator wallet");
        (,,, uint32 gates) = nandout.circuitInfo(id);
        assertEq(gates, 1);

        assertFalse(pad.isLaunched(Addresses.NANDOUT, id));
        vm.recordLogs();
        vm.prank(user);
        address token = pad.createLaunch(
            Addresses.NANDOUT, id, "Fresh Nand", "FNAND", "ipfs://bafkreigh2akiscaildc", Addresses.WOKB, 0, 0
        );
        assertTrue(pad.isLaunched(Addresses.NANDOUT, id), "isLaunched set");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == CurvePad.LaunchCreated.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[3]))), Addresses.NANDOUT);
                (uint256 cid,, address who, string memory uri) =
                    abi.decode(logs[i].data, (uint256, address, address, string));
                assertEq(cid, id);
                assertEq(who, user);
                assertEq(uri, "ipfs://bafkreigh2akiscaildc", "imageURI emitted");
                found = true;
            }
        }
        assertTrue(found, "LaunchCreated emitted");

        vm.roll(block.number + pad.GUARD_BLOCKS());
        vm.prank(user);
        uint256 out = pad.buyWithOKB{value: 0.01 ether}(token, 0, block.timestamp + 600);
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(user), out);
    }

    function test_fork_secondLaunchFromSameNand_reverts_allVariants() public {
        address a = makeAddr("holderA");
        address b = makeAddr("holderB");
        uint256 id = _mintNand(a);
        vm.prank(a);
        pad.createLaunch(Addresses.NANDOUT, id, "One", "ONE", "", Addresses.WOKB, 0, 0);

        // same holder: same name/ticker, different name/ticker, other quote asset
        vm.startPrank(a);
        vm.expectRevert(CurvePad.AlreadyLaunched.selector);
        pad.createLaunch(Addresses.NANDOUT, id, "One", "ONE", "", Addresses.WOKB, 0, 0);
        vm.expectRevert(CurvePad.AlreadyLaunched.selector);
        pad.createLaunch(Addresses.NANDOUT, id, "Two", "TWO", "", Addresses.WOKB, 0, 0);
        vm.expectRevert(CurvePad.AlreadyLaunched.selector);
        pad.createLaunch(Addresses.NANDOUT, id, "Two", "TWO", "", Addresses.BEM, 0, 0);
        nandout.transferFrom(a, b, id);
        vm.stopPrank();

        // new holder after transfer: same and different name/ticker
        vm.startPrank(b);
        vm.expectRevert(CurvePad.AlreadyLaunched.selector);
        pad.createLaunch(Addresses.NANDOUT, id, "One", "ONE", "", Addresses.WOKB, 0, 0);
        vm.expectRevert(CurvePad.AlreadyLaunched.selector);
        pad.createLaunch(Addresses.NANDOUT, id, "Three", "THREE", "", Addresses.WOKB, 0, 0);
        vm.stopPrank();
        assertTrue(pad.isLaunched(Addresses.NANDOUT, id), "still launched after transfer");

        // a different Nand still launches
        uint256 id2 = _mintNand(b);
        vm.prank(b);
        pad.createLaunch(Addresses.NANDOUT, id2, "Three", "THREE", "", Addresses.WOKB, 0, 0);
        assertTrue(pad.isLaunched(Addresses.NANDOUT, id2));
    }
}
