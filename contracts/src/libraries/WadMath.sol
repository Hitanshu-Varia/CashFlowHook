// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title WadMath
/// @notice Shared WAD (1e18) fixed-point helpers. All portfolio values are USD-WAD unless stated.
/// @dev Full-precision mulDiv is used so normal 18-decimal USD magnitudes cannot overflow an
///      intermediate. A result above MAX_GRID_VALUE is rejected with GridOverflow by callers.
library WadMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_GRID_VALUE = 1e40;

    error GridOverflow();

    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, WAD);
    }

    function divWad(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) return 0;
        return Math.mulDiv(a, WAD, b);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function abs(int256 a) internal pure returns (uint256) {
        unchecked {
            return uint256(a < 0 ? -a : a);
        }
    }

    function sqrt(uint256 a) internal pure returns (uint256) {
        return Math.sqrt(a);
    }

    function checkGrid(uint256 value) internal pure returns (uint256) {
        if (value > MAX_GRID_VALUE) revert GridOverflow();
        return value;
    }
}
