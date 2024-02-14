//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./interfaces/IBlast.sol";
import "./whitelist/Whitelist.sol";

struct Token {
    address token;
    uint48 settleTime;
    uint48 settleDuration;
    uint152 settleRate; // number of token per point
    uint8 status; //
}

struct Offer {
    uint8 offerType;
    bytes32 tokenId;
    address exToken;
    uint256 amount;
    uint256 value;
    uint256 collateral;
    uint256 status;
    address offeredBy;
    address filledBy;
}

struct Config {
    uint256 pledgeRate;
    uint256 feeRefund;
    uint256 feeSettle;
    address feeWallet;
}

contract PointsMarket is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 constant WEI6 = 10 ** 6;
    uint8 constant OFFER_BUY = 1;
    uint8 constant OFFER_SELL = 2;

    // Status
    uint8 constant STATUS_OFFER_OPEN = 1;
    uint8 constant STATUS_OFFER_FILLED = 2;
    uint8 constant STATUS_OFFER_CANCELLED = 3;
    uint8 constant STATUS_OFFER_SETTLE_FILLED = 4;
    uint8 constant STATUS_OFFER_SETTLE_CANCELLED = 5;

    uint8 constant STATUS_TOKEN_ACTIVE = 1;
    uint8 constant STATUS_TOKEN_INACTIVE = 2;
    uint8 constant STATUS_TOKEN_SETTLE = 3;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    IBlast public constant BLAST =
        IBlast(0x4300000000000000000000000000000000000002);

    struct PreMarketStorage {
        mapping(address => bool) acceptedTokens;
        mapping(bytes32 => Token) tokens;
        mapping(uint256 => Offer) offers;
        uint256 lastOfferId;
        Config config;
    }

    // keccak256(abi.encode(uint256(keccak256("gibble.xyz.PointsMarket")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PreMarketStorageLocation =
        0x8496807dd2bf40ef0449b1c8abc6a2a63c065c0593131743c641d6d91e9a6c00;

    function _getOwnStorage()
        private
        pure
        returns (PreMarketStorage storage $)
    {
        assembly {
            $.slot := PreMarketStorageLocation
        }
    }

    // event
    event NewToken(bytes32 tokenId, uint256 settleDuration);
    event NewOffer(
        uint256 id,
        uint8 offerType,
        bytes32 tokenId,
        address exToken,
        uint256 amount,
        uint256 value,
        uint256 collateral,
        address doer
    );
    event TakeOffer(uint256 id, address doer);
    event CancelOffer(uint256 offerId, address doer);

    event SettleFilled(
        uint256 offerId,
        uint256 amount,
        uint256 value,
        uint256 fee,
        address doer
    );
    event SettleCancelled(
        uint256 offerId,
        uint256 value,
        uint256 fee,
        address doer
    );

    event UpdateAcceptedTokens(address[] tokens, bool isAccepted);
    event UpdateConfig(
        address oldFeeWallet,
        uint256 oldFeeSettle,
        uint256 oldFeeRefund,
        uint256 oldPledgeRate,
        address newFeeWallet,
        uint256 newFeeSettle,
        uint256 newFeeRefund,
        uint256 newPledgeRate
    );

    event TokenToSettlePhase(
        bytes32 tokenId,
        address token,
        uint256 settleRate,
        uint256 settleTime
    );
    event UpdateTokenStatus(bytes32 tokenId, uint8 oldValue, uint8 newValue);
    event TokenForceCancelSettlePhase(bytes32 tokenId);

    Whitelist public whitelist;

    modifier onlyWhitelisted() {
        require(whitelist.whitelistedAddresses(msg.sender), "Not whitelisted");
        _;
    }

    function initialize(address _whitelistAddress) public initializer {
        __Ownable_init(msg.sender);
        __AccessControl_init_unchained();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        whitelist = Whitelist(_whitelistAddress);
        // init value
        PreMarketStorage storage $ = _getOwnStorage();
        $.config.pledgeRate = WEI6; // 1:1
        $.config.feeWallet = owner();
        $.config.feeSettle = WEI6 / 200; // 0.5%
        $.config.feeRefund = WEI6 / 200; // 0.5%
        // Commented for tests
        BLAST.configureClaimableGas();
    }

    ///////////////////////////
    ////// SYSTEM ACTION //////
    ///////////////////////////

    function createToken(
        bytes32 tokenId,
        uint48 settleDuration
    ) external onlyRole(OPERATOR_ROLE) {
        PreMarketStorage storage $ = _getOwnStorage();
        require(settleDuration >= 24 * 60 * 60, "Minimum 24h for settling");
        Token storage _token = $.tokens[tokenId];

        _token.settleDuration = settleDuration;
        _token.status = STATUS_TOKEN_ACTIVE;
        emit NewToken(tokenId, settleDuration);
    }

    function tokenToSettlePhase(
        bytes32 tokenId,
        address tokenAddress,
        uint152 settleRate // how many token for 1M points
    ) external onlyRole(OPERATOR_ROLE) {
        PreMarketStorage storage $ = _getOwnStorage();
        Token storage _token = $.tokens[tokenId];
        require(tokenAddress != address(0), "Invalid Token Address");
        require(settleRate > 0, "Invalid Settle Rate");
        require(
            _token.status == STATUS_TOKEN_ACTIVE ||
                _token.status == STATUS_TOKEN_INACTIVE,
            "Invalid Token Status"
        );
        _token.token = tokenAddress;
        _token.settleRate = settleRate;
        // update token settle status & time
        _token.status = STATUS_TOKEN_SETTLE;
        _token.settleTime = uint48(block.timestamp);

        emit TokenToSettlePhase(
            tokenId,
            tokenAddress,
            settleRate,
            block.timestamp
        );
    }

    function tokenToggleActivation(
        bytes32 tokenId
    ) external onlyRole(OPERATOR_ROLE) {
        PreMarketStorage storage $ = _getOwnStorage();
        Token storage _token = $.tokens[tokenId];
        uint8 fromStatus = _token.status;
        uint8 toStatus = fromStatus == STATUS_TOKEN_ACTIVE
            ? STATUS_TOKEN_INACTIVE
            : STATUS_TOKEN_ACTIVE;

        require(
            fromStatus == STATUS_TOKEN_ACTIVE ||
                fromStatus == STATUS_TOKEN_INACTIVE,
            "Cannot Change Token Status"
        );

        _token.status = toStatus;
        emit UpdateTokenStatus(tokenId, fromStatus, toStatus);
    }

    // in case wrong setting for settle
    function tokenForceCancelSettlePhase(
        bytes32 tokenId
    ) external onlyRole(OPERATOR_ROLE) {
        PreMarketStorage storage $ = _getOwnStorage();
        Token storage _token = $.tokens[tokenId];
        require(_token.status == STATUS_TOKEN_SETTLE, "Invalid Token Status");
        _token.status = STATUS_TOKEN_INACTIVE;
        emit TokenForceCancelSettlePhase(tokenId);
    }

    // force cancel offer - by Operator
    // refund for both seller & buyer
    function forceCancelOffer(
        uint256 offerId
    ) public nonReentrant onlyRole(OPERATOR_ROLE) {
        PreMarketStorage storage $ = _getOwnStorage();
        Offer storage offer = $.offers[offerId];

        require(
            offer.status == STATUS_OFFER_OPEN ||
                offer.status == STATUS_OFFER_FILLED,
            "Invalid Offer Status"
        );

        // calculate refund
        uint256 buyerRefundValue = 0;
        uint256 sellerRefundValue = 0;
        address buyer = address(0);
        address seller = address(0);
        if (offer.offerType == OFFER_BUY) {
            buyerRefundValue = offer.value; // must refund
            buyer = offer.offeredBy;
            if (offer.status == STATUS_OFFER_FILLED) {
                // only when offer filled
                sellerRefundValue = offer.collateral;
                seller = offer.filledBy;
            }
        } else {
            sellerRefundValue = offer.collateral; // must refund
            seller = offer.offeredBy;
            if (offer.status == STATUS_OFFER_FILLED) {
                // only when offer filled
                buyerRefundValue = offer.value;
                buyer = offer.filledBy;
            }
        }

        // refund
        if (offer.exToken == address(0)) {
            // refund ETH
            if (buyerRefundValue > 0 && buyer != address(0)) {
                (bool success, ) = buyer.call{value: buyerRefundValue}("");
                require(success, "Transfer Funds to Seller Fail");
            }
            if (sellerRefundValue > 0 && seller != address(0)) {
                (bool success, ) = seller.call{value: sellerRefundValue}("");
                require(success, "Transfer Funds to Seller Fail");
            }
        } else {
            IERC20 iexToken = IERC20(offer.exToken);
            if (buyerRefundValue > 0 && buyer != address(0)) {
                iexToken.transfer(buyer, buyerRefundValue);
            }
            if (sellerRefundValue > 0 && seller != address(0)) {
                iexToken.transfer(seller, sellerRefundValue);
            }
        }

        offer.status = STATUS_OFFER_CANCELLED;
        emit CancelOffer(offerId, msg.sender);
    }

    //TODO: change this to treasury address
    function claimMyContractsGas() external onlyRole(OPERATOR_ROLE) {
        BLAST.claimAllGas(address(this), msg.sender);
    }

    /////////////////////////
    ////// USER ACTION //////
    /////////////////////////

    // make a buy request
    function newOffer(
        uint8 offerType,
        bytes32 tokenId,
        uint256 amount,
        uint256 value,
        address exToken
    ) external nonReentrant onlyWhitelisted {
        PreMarketStorage storage $ = _getOwnStorage();
        Token storage token = $.tokens[tokenId];
        require(token.status == STATUS_TOKEN_ACTIVE, "Invalid Token");
        require(
            exToken != address(0) && $.acceptedTokens[exToken],
            "Invalid Offer Token"
        );
        require(amount > 0 && value > 0, "Invalid Amount or Value");
        IERC20 iexToken = IERC20(exToken);
        // collateral
        uint256 collateral = (value * $.config.pledgeRate) / WEI6;

        // transfer offer value (offer buy) or collateral (offer sell)
        uint256 _transferAmount = offerType == OFFER_BUY ? value : collateral;
        iexToken.transferFrom(msg.sender, address(this), _transferAmount);

        // create new offer
        _newOffer(offerType, tokenId, exToken, amount, value, collateral);
    }

    // amount - use standard 6 decimals
    function newOfferETH(
        uint8 offerType,
        bytes32 tokenId,
        uint256 amount,
        uint256 value
    ) external payable nonReentrant onlyWhitelisted {
        PreMarketStorage storage $ = _getOwnStorage();
        Token storage token = $.tokens[tokenId];
        require(token.status == STATUS_TOKEN_ACTIVE, "Invalid Token");
        require(amount > 0 && value > 0, "Invalid Amount or Value");
        // collateral
        uint256 collateral = (value * $.config.pledgeRate) / WEI6;

        uint256 _ethAmount = offerType == OFFER_BUY ? value : collateral;
        require(_ethAmount <= msg.value, "Insufficient Funds");
        // create new offer
        _newOffer(offerType, tokenId, address(0), amount, value, collateral);
    }

    // take a buy request
    function takeOffer(uint256 offerId) external nonReentrant onlyWhitelisted {
        PreMarketStorage storage $ = _getOwnStorage();
        Offer storage offer = $.offers[offerId];
        Token storage token = $.tokens[offer.tokenId];

        // verify existed offer & still open
        require(offer.amount > 0, "Invalid Offer");
        require(offer.status == STATUS_OFFER_OPEN, "Invalid Offer Status");
        require(token.status == STATUS_TOKEN_ACTIVE, "Invalid token Status");
        require(offer.exToken != address(0), "Invalid Offer Token");

        // transfer exchange token to fill order
        uint256 _transferAmount;
        if (offer.offerType == OFFER_BUY) {
            _transferAmount = offer.collateral;
        } else {
            _transferAmount = offer.value;
        }

        IERC20 iexToken = IERC20(offer.exToken);
        iexToken.transferFrom(msg.sender, address(this), _transferAmount);

        // update offer status
        offer.status = STATUS_OFFER_FILLED;
        offer.filledBy = msg.sender;

        emit TakeOffer(offerId, msg.sender);
    }

    function takeOfferETH(
        uint256 offerId
    ) external payable nonReentrant onlyWhitelisted {
        PreMarketStorage storage $ = _getOwnStorage();
        Offer storage offer = $.offers[offerId];
        Token storage token = $.tokens[offer.tokenId];

        // verify existed offer & still open
        require(offer.amount > 0, "Invalid Offer");
        require(offer.status == STATUS_OFFER_OPEN, "Invalid Offer Status");
        require(token.status == STATUS_TOKEN_ACTIVE, "Invalid Token Status");
        require(offer.exToken == address(0), "Invalid Offer Token");

        // transfer exchange token to fill order
        uint256 _ethAmount;
        if (offer.offerType == OFFER_BUY) {
            _ethAmount = offer.collateral; // fill collateral to sell
        } else {
            _ethAmount = offer.value;
        }
        require(msg.value >= _ethAmount, "Insufficient Funds");

        // update offer status
        offer.status = STATUS_OFFER_FILLED;
        offer.filledBy = msg.sender;

        emit TakeOffer(offerId, msg.sender);
    }

    // close unfullfilled offer - by Offer owner
    function cancelOffer(uint256 offerId) public nonReentrant {
        PreMarketStorage storage $ = _getOwnStorage();
        Offer storage offer = $.offers[offerId];

        require(msg.sender == offer.offeredBy, "Offer Owner Only");
        require(offer.status == STATUS_OFFER_OPEN, "Invalid Offer Status");

        // calculate refund
        uint256 refundValue;
        if (offer.offerType == OFFER_BUY) {
            refundValue = offer.value;
        } else {
            refundValue = offer.collateral;
        }
        uint256 refundFee = (refundValue * $.config.feeRefund) / WEI6;
        refundValue -= refundFee;
        // refund
        if (offer.exToken == address(0)) {
            // refund ETH
            (bool success1, ) = offer.offeredBy.call{value: refundValue}("");
            (bool success2, ) = $.config.feeWallet.call{value: refundFee}("");
            require(success1 && success2, "Transfer Funds Fail");
        } else {
            IERC20 iexToken = IERC20(offer.exToken);
            iexToken.transfer(offer.offeredBy, refundValue);
            iexToken.transfer($.config.feeWallet, refundFee);
        }

        offer.status = STATUS_OFFER_CANCELLED;
        emit CancelOffer(offerId, msg.sender);
    }

    // settle order - deliver token to finillize the order
    function settleFilled(uint256 offerId) public nonReentrant {
        PreMarketStorage storage $ = _getOwnStorage();
        Offer storage offer = $.offers[offerId];
        Token storage token = $.tokens[offer.tokenId];

        // check condition
        require(token.status == STATUS_TOKEN_SETTLE, "Invalid Status");
        require(
            token.token != address(0) && token.settleRate > 0,
            "Token Not Set"
        );
        require(
            block.timestamp > token.settleTime,
            "Settling Time Not Started"
        );
        require(offer.status == STATUS_OFFER_FILLED, "Invalid Offer Status");

        address buyer = offer.offerType == OFFER_BUY
            ? offer.offeredBy
            : offer.filledBy;
        address seller = offer.offerType == OFFER_SELL
            ? offer.offeredBy
            : offer.filledBy;

        require(seller == msg.sender, "Seller Only");

        // transfer token to buyer
        IERC20 iToken = IERC20(token.token);
        // calculate token amount base on it's decimals
        uint256 tokenAmount = (offer.amount * token.settleRate) / WEI6;
        // transfer token from seller to buyer
        iToken.transferFrom(seller, buyer, tokenAmount);

        // transfer liquid to seller
        uint256 settleFee = (offer.value * $.config.feeSettle) / WEI6;
        uint256 totalValue = offer.value + offer.collateral - settleFee;
        if (offer.exToken == address(0)) {
            // by ETH
            (bool success1, ) = seller.call{value: totalValue}("");
            (bool success2, ) = $.config.feeWallet.call{value: settleFee}("");
            require(success1 && success2, "Transfer Funds Fail");
        } else {
            // by exToken
            IERC20 iexToken = IERC20(offer.exToken);
            iexToken.transfer(seller, totalValue);
            iexToken.transfer($.config.feeWallet, settleFee);
        }

        offer.status = STATUS_OFFER_SETTLE_FILLED;

        emit SettleFilled(
            offerId,
            tokenAmount,
            totalValue,
            settleFee,
            msg.sender
        );
    }

    // cancel unsettled order by token buyer or by operator after fullfill time frame
    // token seller lose collateral to token buyer
    function settleCancelled(uint256 offerId) public nonReentrant {
        PreMarketStorage storage $ = _getOwnStorage();
        Offer storage offer = $.offers[offerId];
        Token storage token = $.tokens[offer.tokenId];

        // check condition
        require(token.status == STATUS_TOKEN_SETTLE, "Invalid Status");
        require(
            block.timestamp > token.settleTime + token.settleDuration,
            "In Settle Time"
        );
        require(offer.status == STATUS_OFFER_FILLED, "Invalid Offer Status");

        address buyer = offer.offerType == OFFER_BUY
            ? offer.offeredBy
            : offer.filledBy;
        // address seller = offer.offerType == OFFER_SELL ? offer.offeredBy : offer.filledBy;

        require(
            buyer == msg.sender || hasRole(OPERATOR_ROLE, msg.sender),
            "Buyer or Operator Only"
        );

        // transfer liquid to buyer
        uint256 settleFee = (offer.collateral * $.config.feeSettle) / WEI6;
        uint256 totalValue = offer.value + offer.collateral - settleFee;
        if (offer.exToken == address(0)) {
            // by ETH
            (bool success1, ) = buyer.call{value: totalValue}("");
            (bool success2, ) = $.config.feeWallet.call{value: settleFee}("");
            require(success1 && success2, "Transfer Funds Fail");
        } else {
            // by exToken
            IERC20 iexToken = IERC20(offer.exToken);
            iexToken.transfer(buyer, totalValue);
            iexToken.transfer($.config.feeWallet, settleFee);
        }

        offer.status = STATUS_OFFER_SETTLE_CANCELLED;

        emit SettleCancelled(offerId, totalValue, settleFee, msg.sender);
    }

    // Batch actions
    function forceCancelOffers(uint256[] memory offerIds) external {
        for (uint256 i = 0; i < offerIds.length; i++) {
            forceCancelOffer(offerIds[i]);
        }
    }

    function cancelOffers(uint256[] memory offerIds) external {
        for (uint256 i = 0; i < offerIds.length; i++) {
            cancelOffer(offerIds[i]);
        }
    }

    function settleFilleds(uint256[] memory offerIds) public {
        for (uint256 i = 0; i < offerIds.length; i++) {
            settleFilled(offerIds[i]);
        }
    }

    function settleCancelleds(uint256[] memory offerIds) public {
        for (uint256 i = 0; i < offerIds.length; i++) {
            settleCancelled(offerIds[i]);
        }
    }

    ///////////////////////////
    ///////// SETTER //////////
    ///////////////////////////

    function updateConfig(
        address feeWallet_,
        uint256 feeSettle_,
        uint256 feeRefund_,
        uint256 pledgeRate_
    ) external onlyRole(OPERATOR_ROLE) {
        PreMarketStorage storage $ = _getOwnStorage();
        require(feeWallet_ != address(0), "Invalid Address");
        require(feeSettle_ <= WEI6 / 100, "Settle Fee <= 10%");
        require(feeRefund_ <= WEI6 / 100, "Cancel Fee <= 10%");

        emit UpdateConfig(
            $.config.feeWallet,
            $.config.feeSettle,
            $.config.feeRefund,
            $.config.pledgeRate,
            feeWallet_,
            feeSettle_,
            feeRefund_,
            pledgeRate_
        );
        // update
        $.config.feeWallet = feeWallet_;
        $.config.feeSettle = feeSettle_;
        $.config.feeRefund = feeRefund_;
        $.config.pledgeRate = pledgeRate_;
    }

    function setAcceptedTokens(
        address[] memory tokenAddresses,
        bool isAccepted
    ) external onlyRole(OPERATOR_ROLE) {
        PreMarketStorage storage $ = _getOwnStorage();

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            $.acceptedTokens[tokenAddresses[i]] = isAccepted;
        }
        emit UpdateAcceptedTokens(tokenAddresses, isAccepted);
    }

    ///////////////////////////
    ///////// GETTER //////////
    ///////////////////////////
    function offerAmount(uint256 offerId) external view returns (uint256) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.offers[offerId].amount;
    }

    function offerValue(uint256 offerId) external view returns (uint256) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.offers[offerId].value;
    }

    function offerExToken(uint256 offerId) external view returns (address) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.offers[offerId].exToken;
    }

    function isBuyOffer(uint256 offerId) external view returns (bool) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.offers[offerId].offerType == OFFER_BUY;
    }

    function isSellOffer(uint256 offerId) external view returns (bool) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.offers[offerId].offerType == OFFER_SELL;
    }

    function offerStatus(uint256 offerId) external view returns (uint256) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.offers[offerId].status;
    }

    function offers(uint256 id) external view returns (Offer memory) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.offers[id];
    }

    function tokens(bytes32 id) external view returns (Token memory) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.tokens[id];
    }

    function feeSettle() external view returns (uint256) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.config.feeSettle;
    }

    function feeRefund() external view returns (uint256) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.config.feeRefund;
    }

    function feeWallet() external view returns (address) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.config.feeWallet;
    }

    function pledgeRate() external view returns (uint256) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.config.pledgeRate;
    }

    function isAcceptedToken(address token) external view returns (bool) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.acceptedTokens[token];
    }

    function lastOfferId() external view returns (uint256) {
        PreMarketStorage storage $ = _getOwnStorage();
        return $.lastOfferId;
    }

    ///////////////////////////
    //////// INTERNAL /////////
    ///////////////////////////

    function _newOffer(
        uint8 offerType,
        bytes32 tokenId,
        address exToken,
        uint256 amount,
        uint256 value,
        uint256 collateral
    ) internal {
        PreMarketStorage storage $ = _getOwnStorage();
        // create new offer
        $.offers[++$.lastOfferId] = Offer(
            offerType,
            tokenId,
            exToken,
            amount,
            value,
            collateral,
            STATUS_OFFER_OPEN,
            msg.sender,
            address(0)
        );

        emit NewOffer(
            $.lastOfferId,
            offerType,
            tokenId,
            exToken,
            amount,
            value,
            collateral,
            msg.sender
        );
    }
}
