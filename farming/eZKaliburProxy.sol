// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;

import "./utils/SafeBEP20.sol";
import "./access/OwnableUpgradeable.sol";
import "./library/WhitelistUpgradeable.sol";

contract eZKaliburProxy is OwnableUpgradeable, WhitelistUpgradeable {
    using SafeBEP20 for IBEP20;

    IBEP20 private token;

    function initialize(IBEP20 _token) external initializer {
        __Ownable_init();
        token = _token;
    }

    function safeMeerkatTransfer(address to, uint256 amount) external onlyWhitelisted returns (uint256) {
        uint256 meerkatBal = token.balanceOf(address(this));
        if (amount > meerkatBal) {
            token.transfer(to, meerkatBal);
            return meerkatBal;
        } else {
            token.transfer(to, amount);
            return amount;
        }
    }

    function recoverToken(IBEP20 _token, uint256 _amount, address _to) external onlyOwner {
        require(address(_token) != address(token));
        _token.safeTransfer(_to, _amount);
    }
}