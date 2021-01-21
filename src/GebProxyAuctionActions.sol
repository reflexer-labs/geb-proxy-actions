/// GebProxyActions.sol

// Copyright (C) 2018-2020 Maker Ecosystem Growth Holdings, INC.

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.6.7;

import "./GebProxyActions.sol";

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a DSProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

abstract contract AccountingEngineLike {
    function debtAuctionHouse() external virtual returns (address);
    function surplusAuctionHouse() external virtual returns (address);
    function auctionDebt() external virtual returns (uint256);
    function auctionSurplus() external virtual returns (uint256);
}

abstract contract DebtAuctionHouseLike {
    function bids(uint) external virtual returns (uint, uint, address, uint48, uint48);
    function decreaseSoldAmount(uint256, uint256, uint256) external virtual;
    function restartAuction(uint256) external virtual;
    function settleAuction(uint256) external virtual;
    function protocolToken() external virtual returns (address);
}

abstract contract SurplusAuctionHouseLike {
    function bids(uint) external virtual returns (uint, uint, address, uint48, uint48);
    function increaseBidSize(uint256 id, uint256 amountToBuy, uint256 bid) external virtual;
    function restartAuction(uint256) external virtual;
    function settleAuction(uint256) external virtual;
    function protocolToken() external virtual returns (address);
}

contract AuctionCommon {

    /// @notice Claims the full balance of any ERC20 token in the proxy's balance
    /// @param tokenAddress Address of the token
    function claimProxyFunds(address tokenAddress) public {
        DSTokenLike token = DSTokenLike(tokenAddress);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }

    /// @notice Claims the full balance of several ERC20 tokens in the proxy's balance
    /// @param tokenAddresses Addresses of the tokens
    function claimProxyFunds(address[] memory tokenAddresses) public {
        for (uint i = 0; i < tokenAddresses.length; i++)
            claimProxyFunds(tokenAddresses[i]);
    }

    // --- Utils ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    function toWad(uint rad) internal pure returns (uint wad) {
        wad = rad / 10**27;
    }
}

contract GebProxyDebtAuctionActions is Common, AuctionCommon {

    /// @notice Starts auction and bids
    /// @param coinJoin CoinJoin
    /// @param accountingEngineAddress AccountingEngine
    /// @param amountToBuy Amount to Buy
    function startAndDecreaseSoldAmount(address coinJoin, address accountingEngineAddress, uint amountToBuy) public {
        AccountingEngineLike accountingEngine = AccountingEngineLike(accountingEngineAddress);
        DebtAuctionHouseLike debtAuctionHouse = DebtAuctionHouseLike(accountingEngine.debtAuctionHouse());
        SAFEEngineLike safeEngine = SAFEEngineLike(CoinJoinLike(coinJoin).safeEngine());

        // Starts auction
        uint auctionId = accountingEngine.auctionDebt();
        (uint bidAmount,,,,) = debtAuctionHouse.bids(auctionId);
        // Joins system
        coinJoin_join(coinJoin, address(this), amountToBuy);
        // Allows auctionHouse to access to proxy's COIN balance in the safeEngine
        if (safeEngine.canModifySAFE(address(this), address(debtAuctionHouse)) == 0) {
            safeEngine.approveSAFEModification(address(debtAuctionHouse));
        }
        // Bid
        debtAuctionHouse.decreaseSoldAmount(auctionId, amountToBuy, bidAmount);
    }

    /// @notice Bids on auction. Restarts the auction if necessary
    /// @param coinJoin CoinJoin
    /// @param auctionHouse Auction house address
    /// @param auctionId Auction Id
    /// @param amountToBuy Amount to Buy
    function decreaseSoldAmount(address coinJoin, address auctionHouse, uint auctionId, uint amountToBuy) public {
        DebtAuctionHouseLike debtAuctionHouse = DebtAuctionHouseLike(auctionHouse);
        SAFEEngineLike safeEngine = SAFEEngineLike(CoinJoinLike(coinJoin).safeEngine());

        (uint bidAmount,,, uint48 bidExpiry, uint48 auctionDeadline) = debtAuctionHouse.bids(auctionId); 
        // Joins system
        coinJoin_join(coinJoin, address(this), amountToBuy);
        // Allows auctionHouse to access to proxy's COIN balance in the safeEngine
        if (safeEngine.canModifySAFE(address(this), address(debtAuctionHouse)) == 0) {
            safeEngine.approveSAFEModification(address(debtAuctionHouse));
        }
        // Restarts auction if inactive
        if (both(auctionDeadline < now, bidExpiry == 0)) {
            debtAuctionHouse.restartAuction(auctionId);
        }
        //Bid
        debtAuctionHouse.decreaseSoldAmount(auctionId, amountToBuy, bidAmount);
    }

    /// @notice Mints Protocol token for your proxy and then the proxy sends all of its balance to msg.sender
    /// @param coinJoin CoinJoin
    /// @param auctionHouse Auction house address
    /// @param auctionId Auction Id
    function settleAuction(address coinJoin, address auctionHouse, uint auctionId) public {
        DebtAuctionHouseLike debtAuctionHouse = DebtAuctionHouseLike(auctionHouse);
        debtAuctionHouse.settleAuction(auctionId);
        claimProxyFunds(address(CoinJoinLike(coinJoin).systemCoin()));
        claimProxyFunds(debtAuctionHouse.protocolToken());
    }
}

contract GebProxySurplusAuctionActions is Common, AuctionCommon {

    /// @notice Starts surplus auction and bids
    /// @param accountingEngineAddress AccountingEngine
    /// @param bidSize Bid size
    function startAndIncreaseBidSize(address accountingEngineAddress, uint bidSize) public {
        AccountingEngineLike accountingEngine = AccountingEngineLike(accountingEngineAddress);
        SurplusAuctionHouseLike surplusAuctionHouse = SurplusAuctionHouseLike(accountingEngine.surplusAuctionHouse());
        DSTokenLike protocolToken = DSTokenLike(surplusAuctionHouse.protocolToken());

        // Starts auction
        uint auctionId = accountingEngine.auctionSurplus();
        require(protocolToken.transferFrom(msg.sender, address(this), bidSize), "geb-proxy-auction-actions/transfer-from-failed");
        protocolToken.approve(address(surplusAuctionHouse), bidSize);
        (, uint amountToSell,,,) = surplusAuctionHouse.bids(auctionId);
        // Bid
        surplusAuctionHouse.increaseBidSize(auctionId, amountToSell, bidSize);
    }

    /// @notice Bids in auction. Restarts the auction if necessary
    /// @param auctionHouse Auction house address
    /// @param auctionId Auction Id
    /// @param bidSize Bid size
    function increaseBidSize(address auctionHouse, uint auctionId, uint bidSize) public {
        SurplusAuctionHouseLike surplusAuctionHouse = SurplusAuctionHouseLike(auctionHouse);
        DSTokenLike protocolToken = DSTokenLike(surplusAuctionHouse.protocolToken());

        require(protocolToken.transferFrom(msg.sender, address(this), bidSize), "geb-proxy-auction-actions/transfer-from-failed");
        protocolToken.approve(address(surplusAuctionHouse), bidSize);
        // Restarts auction if inactive
        (, uint amountToSell,, uint48 bidExpiry, uint48 auctionDeadline) = surplusAuctionHouse.bids(auctionId); 
        if (auctionDeadline < now && bidExpiry == 0) {
            surplusAuctionHouse.restartAuction(auctionId);
        }      
        // Bid 
        surplusAuctionHouse.increaseBidSize(auctionId, amountToSell, bidSize);
    }

    /// @notice Mints system coin for your proxy and then the proxy sends all of its balance to msg.sender
    /// @param coinJoin CoinJoin
    /// @param auctionHouse Auction house address
    /// @param auctionId Auction Id
    function settleAuction(address coinJoin, address auctionHouse, uint auctionId) public {
        SurplusAuctionHouseLike surplusAuctionHouse = SurplusAuctionHouseLike(auctionHouse);
        SAFEEngineLike safeEngine = SAFEEngineLike(CoinJoinLike(coinJoin).safeEngine());
        (, uint amountToBuy,,,) = surplusAuctionHouse.bids(auctionId); 
        // Settle auction
        surplusAuctionHouse.settleAuction(auctionId);
        // Allows coinJoin to access to proxy's COIN balance in the safeEngine
        if (safeEngine.canModifySAFE(address(this), address(coinJoin)) == 0) {
            safeEngine.approveSAFEModification(address(coinJoin));
        }
        // Exits Coin and Protocol token to the owner
        CoinJoinLike(coinJoin).exit(msg.sender, toWad(amountToBuy));
        claimProxyFunds(surplusAuctionHouse.protocolToken());
    }
}

