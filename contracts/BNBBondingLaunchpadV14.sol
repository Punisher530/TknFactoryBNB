// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/**
 * BNBBondingLaunchpadV14
 * BNB Smart Chain MAINNET ONLY (chainId 56).
 * Independent fork of EVMBondingLaunchpadV1, with PancakeSwap V2 addresses
 * fixed in bytecode. No chain, router, factory, WBNB, LP receiver, owner,
 * blacklist, migration admin, or fee-rate configuration.
 *
 * Experimental isolated candidate: the final buy completes the curve without
 * calling PancakeSwap. Anyone may then call graduate() to atomically seed LP.
 * If migration fails, ONLY the graduate() transaction reverts; curve holders
 * may still sell, which reopens buying and invalidates the pending graduation.
 * There is no READY sell lock, 48-hour expiry, or privileged recovery function.
 * WARNING: sells can race and invalidate graduate() until the curve is full again.
 * No guaranteed keeper funding or automatic graduation is provided.
 * WARNING: such WBNB donations affect DEX opening price. Never assume LP
 * opening price exactly equals the terminal bonding-curve spot price.
 *
 * v1.4 price-preview logic is preserved unchanged in this prototype.
 * External WBNB donations remain in the pool; price reporting is not a price cap.
 * SECURITY STATUS: EXPERIMENTAL / MAINNET HOLD.
 * Real compiler, BSC-fork, gas, MEV, and security tests required before real funds.
 */

interface IPancakeFactoryV14 {
    function getPair(address a, address b) external view returns (address);
    function createPair(address a, address b) external returns (address);
}

interface IPancakePairV14 {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address to) external returns (uint256 liquidity);
}

interface IWBNBV14 {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract BNBBondingTokenV14 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public immutable launchpad;
    bool public transfersUnlocked;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event TransfersUnlocked();

    error NotLaunchpad();
    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error CurveTransfersRestricted();

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert NotLaunchpad();
        _;
    }

    constructor(string memory name_, string memory symbol_, address launchpad_) {
        if (launchpad_ == address(0)) revert InvalidAddress();
        name = name_;
        symbol = symbol_;
        launchpad = launchpad_;
        totalSupply = 1_000_000_000 ether;
        balanceOf[launchpad_] = totalSupply;
        emit Transfer(address(0), launchpad_, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert InvalidAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 available = allowance[from][msg.sender];
        if (available != type(uint256).max) {
            if (available < amount) revert InsufficientAllowance();
            unchecked { allowance[from][msg.sender] = available - amount; }
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function unlockTransfers() external onlyLaunchpad {
        if (!transfersUnlocked) {
            transfersUnlocked = true;
            emit TransfersUnlocked();
        }
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        if (!transfersUnlocked) {
            // Outbound buy and atomic LP seed: only launchpad has token custody.
            // Inbound sell: launchpad calls transferFrom with buyer allowance.
            if (from != launchpad && !(to == launchpad && msg.sender == launchpad)) {
                revert CurveTransfersRestricted();
            }
        }
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked { balanceOf[from] = bal - amount; }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract BNBBondingLaunchpadV14 {
    uint256 public constant BSC_CHAIN_ID = 56;
    // Canonical BNB Smart Chain mainnet PancakeSwap V2 addresses.
    address public constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    uint256 public constant BPS = 10_000;
    uint256 public constant TRADE_FEE_BPS = 100; // 1%, not owner-adjustable
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant LP_SUPPLY = 200_000_000 ether;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    struct Market {
        address creator;
        uint256 curveTokensRemaining;
        uint256 virtualTokenReserve;
        uint256 virtualNativeReserve;
        uint256 nativeReserve;
        uint64 createdAt;
        bool graduated;
    }

    address public immutable feeRecipient;
    uint256 public immutable initialVirtualNativeReserve;
    uint256 public immutable initialVirtualTokenReserve;
    uint256 public immutable finalVirtualTokenReserve;
    uint256 public immutable invariantK;

    mapping(address => Market) public markets;
    mapping(address => bool) public isLaunchToken;
    mapping(address => uint256) public nativeCredits;
    address[] private _tokens;
    uint256 public feesAccrued;
    uint256 private _entered;

    event TokenCreated(
        address indexed token, address indexed creator,
        string name, string symbol, string metadataURI
    );
    event Bought(
        address indexed token, address indexed buyer,
        uint256 grossNativeUsed, uint256 tokensOut, uint256 fee, uint256 refundCredit
    );
    event Sold(
        address indexed token, address indexed seller,
        uint256 tokensIn, uint256 nativeCredit, uint256 fee
    );
    event Graduated(
        address indexed token, address indexed pair,
        uint256 tokensIntoLP, uint256 nativeIntoLP,
        uint256 lpTokensMinted, address lpRecipient
    );
    // Emitted on an exhausted curve; migration is separately permissionless.
    // A later sell can reopen the curve before graduate() is executed.
    event GraduationReady(address indexed token, uint256 nativeReserve);
    event NativeCreditClaimed(address indexed account, uint256 amount);
    event FeesClaimed(address indexed recipient, uint256 amount);
    // Donated WBNB remains in the pool and changes the opening DEX price.
    event GraduationPoolDonation(address indexed token, address indexed pair, uint256 wbnbBeforeDeposit);
    // Immutable, transaction-time measurement, not a promise that spot price
    // remains unchanged after DEX swaps. Raw prices are wei BNB per 1e18 token units.
    // Deviation is upward BPS versus intended initial LP seed price, NOT
    // versus the bonding curve terminal spot price.
    event GraduationOpeningPrice(
        address indexed token,
        address indexed pair,
        uint256 expectedNativeIntoLP,
        uint256 donatedWBNB,
        uint256 intendedWeiPerToken,
        uint256 actualWeiPerToken,
        uint256 upwardDeviationBps
    );

    error InvalidConfig();
    error InvalidTokenMetadata();
    error UnrecognizedToken();
    error AlreadyGraduated();
    error NotReadyForGraduation();
    error CurveExhausted();
    error DeadlinePassed();
    error InvalidAmount();
    error Slippage();
    error NotEnoughNative();
    error NotEnoughCurveTokens();
    error InvalidPairState();
    error LiquidityMismatch();
    error NothingToClaim();
    error NativeSendFailed();
    error Reentrancy();
    error WrongChain();
    error WrappedTransferFailed();

    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    // Constructor cannot be deployed on BSC testnet (97), Ethereum (1), etc.
    // For local testing use a mainnet fork or a test harness with chainId 56.
    constructor(address feeRecipient_, uint256 virtualBNBReserveWei_) {
        if (block.chainid != BSC_CHAIN_ID) revert WrongChain();
        if (feeRecipient_ == address(0)) revert InvalidConfig();
        if (virtualBNBReserveWei_ < 1 gwei || virtualBNBReserveWei_ > 1_000_000 ether) {
            revert InvalidConfig();
        }
        // Guard against empty/mistyped canonical deployments on the running network.
        if (PANCAKE_V2_FACTORY.code.length == 0 ||
            PANCAKE_V2_ROUTER.code.length == 0 || WBNB.code.length == 0) revert InvalidConfig();
        feeRecipient = feeRecipient_;
        initialVirtualNativeReserve = virtualBNBReserveWei_;

        // Keep previous curve geometry exactly; use native BNB in all equations.
        uint256 offset = (LP_SUPPLY * CURVE_SUPPLY) / (CURVE_SUPPLY - LP_SUPPLY);
        finalVirtualTokenReserve = offset;
        uint256 initialTokens = CURVE_SUPPLY + offset;
        initialVirtualTokenReserve = initialTokens;
        invariantK = initialTokens * virtualBNBReserveWei_;
    }

    // Do not accept unexpected BNB transfers; buys are explicit payable functions.
    receive() external payable { revert InvalidConfig(); }

    modifier onlyBSC() {
        if (block.chainid != BSC_CHAIN_ID) revert WrongChain();
        _;
    }

    function createToken(string calldata name_, string calldata symbol_, string calldata metadataURI)
        external onlyBSC nonReentrant returns (address token)
    {
        return _createToken(name_, symbol_, metadataURI);
    }

    // Creator token deployment and buy are atomic; a finishing buy never calls
    // PancakeSwap in this candidate. Graduation is a separate transaction.
    function createTokenAndBuy(
        string calldata name_, string calldata symbol_, string calldata metadataURI,
        uint256 minInitialTokensOut, uint256 deadline
    ) external payable onlyBSC nonReentrant returns (address token, uint256 tokensOut) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (msg.value == 0) revert InvalidAmount();
        token = _createToken(name_, symbol_, metadataURI);
        tokensOut = _executeBuy(token, msg.sender, msg.value, minInitialTokensOut);
    }

    function _createToken(string calldata name_, string calldata symbol_, string calldata metadataURI)
        internal returns (address token)
    {
        if (bytes(name_).length == 0 || bytes(name_).length > 64 ||
            bytes(symbol_).length == 0 || bytes(symbol_).length > 16 ||
            bytes(metadataURI).length > 512) revert InvalidTokenMetadata();

        BNBBondingTokenV14 newToken = new BNBBondingTokenV14(name_, symbol_, address(this));
        token = address(newToken);
        markets[token] = Market({
            creator: msg.sender,
            curveTokensRemaining: CURVE_SUPPLY,
            virtualTokenReserve: initialVirtualTokenReserve,
            virtualNativeReserve: initialVirtualNativeReserve,
            nativeReserve: 0,
            createdAt: uint64(block.timestamp),
            graduated: false
        });
        isLaunchToken[token] = true;
        _tokens.push(token);
        emit TokenCreated(token, msg.sender, name_, symbol_, metadataURI);
    }

    function buy(address token, uint256 minTokensOut, uint256 deadline)
        external payable onlyBSC nonReentrant returns (uint256 tokensOut)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (msg.value == 0) revert InvalidAmount();
        return _executeBuy(token, msg.sender, msg.value, minTokensOut);
    }

    function _executeBuy(address token, address buyer, uint256 grossNative, uint256 minTokensOut)
        internal returns (uint256 tokensOut)
    {
        Market storage m = _activeMarket(token);
        (uint256 quoted, uint256 used, uint256 refund, uint256 fee, bool completed) = _quoteBuy(m, grossNative);
        if (quoted == 0 || quoted < minTokensOut) revert Slippage();
        uint256 netNative = used - fee;
        m.curveTokensRemaining -= quoted;
        m.nativeReserve += netNative;
        m.virtualNativeReserve += netNative;
        m.virtualTokenReserve = completed ? finalVirtualTokenReserve : _ceilDiv(invariantK, m.virtualNativeReserve);
        feesAccrued += fee;
        if (refund != 0) nativeCredits[buyer] += refund;
        require(BNBBondingTokenV14(token).transfer(buyer, quoted), "TOKEN_TRANSFER_FAILED");
        emit Bought(token, buyer, used, quoted, fee, refund);
        // No DEX dependency on the finishing purchase. If migration later
        // fails, the buyer still owns purchased tokens and may sell to the curve.
        if (completed) emit GraduationReady(token, m.nativeReserve);
        return quoted;
    }

    function sell(address token, uint256 tokensIn, uint256 minNativeOut, uint256 deadline)
        external onlyBSC nonReentrant returns (uint256 nativeOut)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (tokensIn == 0) revert InvalidAmount();
        Market storage m = _activeMarket(token);
        uint256 fee;
        uint256 grossNative;
        uint256 newVirtualNative;
        (nativeOut, fee, grossNative, newVirtualNative) = _quoteSell(m, tokensIn);
        if (nativeOut == 0 || nativeOut < minNativeOut) revert Slippage();

        require(BNBBondingTokenV14(token).transferFrom(msg.sender, address(this), tokensIn), "SELL_TRANSFER_FAILED");
        m.curveTokensRemaining += tokensIn;
        m.virtualTokenReserve += tokensIn;
        m.virtualNativeReserve = newVirtualNative;
        m.nativeReserve -= grossNative;
        nativeCredits[msg.sender] += nativeOut;
        feesAccrued += fee;
        emit Sold(token, msg.sender, tokensIn, nativeOut, fee);
    }

    /**
     * Anyone may retry liquidity seeding after the curve is exhausted.
     * Reverting on a bad DEX leaves the curve ungraduated; holders may sell.
     * A sell before this transaction makes curveTokensRemaining nonzero and
     * this call reverts without touching the accumulated BNB reserve.
     */
    function graduate(address token) external onlyBSC nonReentrant {
        Market storage m = _activeMarket(token);
        _graduateAtomic(token, m);
    }

    /**
     * Atomic PancakeSwap V2 graduation in its OWN transaction, not the buy.
     * Direct LP minting tolerates WBNB donations, which alter opening price.
     * If any step fails, the entire graduation transaction reverts and users
     * retain their bonding-curve exit via sell() (but racing sells can delay LP).
     */
    function _graduateAtomic(address token, Market storage m) internal {
        // Defend future refactors from making partial or premature migration.
        if (m.graduated || m.curveTokensRemaining != 0) revert NotReadyForGraduation();
        uint256 nativeForLP = m.nativeReserve;
        if (nativeForLP == 0) revert NotEnoughNative();

        (address pair, uint256 existingWBNB) = _checkedGraduationPair(token);
        // Effects first, then external calls. Migration effects revert atomically.
        m.graduated = true;
        m.nativeReserve = 0;
        IWBNBV14(WBNB).deposit{value: nativeForLP}();
        if (!IWBNBV14(WBNB).transfer(pair, nativeForLP)) revert WrappedTransferFailed();
        require(BNBBondingTokenV14(token).transfer(pair, LP_SUPPLY), "LP_TOKEN_TRANSFER_FAILED");

        // All minted LP permanently sent to burn address: no ordinary owner
        // and no configurable LP receiver or later removeLiquidity function.
        uint256 mintedLP = IPancakePairV14(pair).mint(BURN_ADDRESS);
        _verifyMint(token, pair, existingWBNB, nativeForLP, mintedLP);
        BNBBondingTokenV14(token).unlockTransfers();
        // Post-mint observation: never conditional or used as a graduation gate.
        // Pair balances are already independently verified by _verifyMint.
        uint256 seedPrice = (nativeForLP * 1 ether) / LP_SUPPLY;
        uint256 openingPrice = ((existingWBNB + nativeForLP) * 1 ether) / LP_SUPPLY;
        uint256 deviationBps = (existingWBNB * BPS) / nativeForLP;
        emit GraduationOpeningPrice(token, pair, nativeForLP, existingWBNB,
                                   seedPrice, openingPrice, deviationBps);
        if (existingWBNB != 0) emit GraduationPoolDonation(token, pair, existingWBNB);
        emit Graduated(token, pair, LP_SUPPLY, nativeForLP, mintedLP, BURN_ADDRESS);
    }

    function _checkedGraduationPair(address token) internal returns (address pair, uint256 existingWBNB) {
        IPancakeFactoryV14 factory = IPancakeFactoryV14(PANCAKE_V2_FACTORY);
        pair = factory.getPair(token, WBNB);
        if (pair == address(0)) pair = factory.createPair(token, WBNB);
        if (pair.code.length == 0) revert InvalidPairState();
        IPancakePairV14 lp = IPancakePairV14(pair);
        if (lp.factory() != PANCAKE_V2_FACTORY) revert InvalidPairState();
        address a = lp.token0();
        address b = lp.token1();
        if (!((a == token && b == WBNB) || (b == token && a == WBNB))) {
            revert InvalidPairState();
        }
        (uint112 reserve0, uint112 reserve1, ) = lp.getReserves();
        uint256 tokenReserve = a == token ? uint256(reserve0) : uint256(reserve1);
        if (lp.totalSupply() != 0 || tokenReserve != 0 ||
            BNBBondingTokenV14(token).balanceOf(pair) != 0) revert InvalidPairState();
        // Nonzero WBNB is tolerated even when synced into pool reserves.
        existingWBNB = IWBNBV14(WBNB).balanceOf(pair);
    }

    function _verifyMint(address token, address pair, uint256 existingWBNB,
                         uint256 nativeForLP, uint256 mintedLP) internal view {
        if (mintedLP == 0 || IPancakePairV14(pair).balanceOf(BURN_ADDRESS) < mintedLP ||
            BNBBondingTokenV14(token).balanceOf(pair) != LP_SUPPLY ||
            IWBNBV14(WBNB).balanceOf(pair) != existingWBNB + nativeForLP) {
            revert LiquidityMismatch();
        }
    }

    function claimNativeCredit() external onlyBSC nonReentrant {
        uint256 amount = nativeCredits[msg.sender];
        if (amount == 0) revert NothingToClaim();
        nativeCredits[msg.sender] = 0;
        _sendNative(payable(msg.sender), amount);
        emit NativeCreditClaimed(msg.sender, amount);
    }

    // Anyone may trigger payout; coins can only go to the immutable recipient.
    function claimProtocolFees() external onlyBSC nonReentrant {
        uint256 amount = feesAccrued;
        if (amount == 0) revert NothingToClaim();
        feesAccrued = 0;
        _sendNative(payable(feeRecipient), amount);
        emit FeesClaimed(feeRecipient, amount);
    }

    function quoteBuy(address token, uint256 grossNative)
        external view returns (uint256 tokensOut, uint256 grossUsed, uint256 refund, uint256 fee, bool completesCurve)
    {
        if (!isLaunchToken[token] || markets[token].graduated || grossNative == 0) {
            return (0, 0, grossNative, 0, false);
        }
        Market storage m = markets[token];
        if (m.curveTokensRemaining == 0) return (0, 0, grossNative, 0, false);
        return _quoteBuy(m, grossNative);
    }

    /**
     * @notice Live, NON-BINDING preview for the website before a finishing buy.
     * @dev The preview assumes an immediate successful finish and no intermediate
     *      buys/sells/donations. MEV can change balances after eth_call. Do NOT
     *      use this to reject a buy or migration. All amounts denominated in wei.
     *      Intended price means LP seed price, not terminal bonding-curve spot.
     *      An already-graduated token must read the emitted OpeningPrice event.
     */
    function graduationPricePreview(address token)
        external view returns (
            uint256 expectedNativeIntoLP,
            uint256 observedWBNBDonation,
            uint256 intendedWeiPerToken,
            uint256 projectedWeiPerToken,
            uint256 upwardDeviationBps
        )
    {
        if (!isLaunchToken[token]) revert UnrecognizedToken();
        Market storage m = markets[token];
        if (m.graduated) revert AlreadyGraduated();
        uint256 endVirtualNative = _ceilDiv(invariantK, finalVirtualTokenReserve);
        uint256 netToFinish = endVirtualNative - m.virtualNativeReserve;
        expectedNativeIntoLP = m.nativeReserve + netToFinish;
        // May be zero if no valid market funding, but not expected for a
        // functioning live market. Return zeros instead of dividing by zero.
        address pair = IPancakeFactoryV14(PANCAKE_V2_FACTORY).getPair(token, WBNB);
        if (pair != address(0)) observedWBNBDonation = IWBNBV14(WBNB).balanceOf(pair);
        intendedWeiPerToken = (expectedNativeIntoLP * 1 ether) / LP_SUPPLY;
        projectedWeiPerToken = ((expectedNativeIntoLP + observedWBNBDonation) * 1 ether) / LP_SUPPLY;
        if (expectedNativeIntoLP != 0) {
            upwardDeviationBps = (observedWBNBDonation * BPS) / expectedNativeIntoLP;
        }
    }

    function quoteSell(address token, uint256 tokensIn) external view returns (uint256 nativeOut, uint256 fee) {
        if (!isLaunchToken[token] || markets[token].graduated || tokensIn == 0) return (0, 0);
        (nativeOut, fee, , ) = _quoteSell(markets[token], tokensIn);
    }

    // Frontend: a completing buy emits GraduationReady; graduate() is separate.
    function grossNativeToFinish(address token) external view returns (uint256) {
        if (!isLaunchToken[token] || markets[token].graduated || markets[token].curveTokensRemaining == 0) return 0;
        Market storage m = markets[token];
        uint256 endNative = _ceilDiv(invariantK, finalVirtualTokenReserve);
        return _grossForNet(endNative - m.virtualNativeReserve);
    }

    function spotPriceWeiPerToken(address token) external view returns (uint256) {
        if (!isLaunchToken[token]) return 0;
        Market storage m = markets[token];
        return (m.virtualNativeReserve * 1 ether) / m.virtualTokenReserve;
    }

    function progressBps(address token) external view returns (uint256) {
        if (!isLaunchToken[token]) return 0;
        Market storage m = markets[token];
        if (m.graduated) return BPS;
        return ((CURVE_SUPPLY - m.curveTokensRemaining) * BPS) / CURVE_SUPPLY;
    }

    function projectedGraduationFDVNative(address token) external view returns (uint256) {
        if (!isLaunchToken[token]) return 0;
        return (TOTAL_SUPPLY * _ceilDiv(invariantK, finalVirtualTokenReserve)) / finalVirtualTokenReserve;
    }

    function tokenCount() external view returns (uint256) { return _tokens.length; }
    function tokenAt(uint256 index) external view returns (address) { return _tokens[index]; }

    function getTokens(uint256 start, uint256 count) external view returns (address[] memory result) {
        uint256 len = _tokens.length;
        if (start >= len || count == 0) return new address[](0);
        // Clamped to avoid start+count integer overflow and unbounded API calls.
        if (count > 100) count = 100;
        uint256 take = count > len - start ? len - start : count;
        result = new address[](take);
        for (uint256 i = 0; i < take; ++i) result[i] = _tokens[start + i];
    }

    function _activeMarket(address token) internal view returns (Market storage m) {
        if (!isLaunchToken[token]) revert UnrecognizedToken();
        m = markets[token];
        if (m.graduated) revert AlreadyGraduated();
    }

    function _quoteBuy(Market storage m, uint256 grossNative)
        internal view returns (uint256 tokensOut, uint256 grossUsed, uint256 refund, uint256 fee, bool completed)
    {
        if (m.curveTokensRemaining == 0) revert CurveExhausted();
        uint256 endNative = _ceilDiv(invariantK, finalVirtualTokenReserve);
        uint256 nativeNeeded = endNative - m.virtualNativeReserve;
        uint256 toFinish = _grossForNet(nativeNeeded);
        grossUsed = grossNative < toFinish ? grossNative : toFinish;
        refund = grossNative - grossUsed;
        completed = grossUsed == toFinish;
        if (completed) {
            fee = grossUsed - nativeNeeded;
            tokensOut = m.curveTokensRemaining;
        } else {
            fee = (grossUsed * TRADE_FEE_BPS) / BPS;
            uint256 netNative = grossUsed - fee;
            if (netNative == 0) return (0, grossUsed, refund, fee, false);
            uint256 newVNative = m.virtualNativeReserve + netNative;
            uint256 newVTokens = _ceilDiv(invariantK, newVNative);
            if (newVTokens >= m.virtualTokenReserve) return (0, grossUsed, refund, fee, false);
            tokensOut = m.virtualTokenReserve - newVTokens;
            if (tokensOut > m.curveTokensRemaining) revert NotEnoughCurveTokens();
        }
    }

    function _quoteSell(Market storage m, uint256 tokensIn)
        internal view returns (uint256 nativeOut, uint256 fee, uint256 grossNative, uint256 newVirtualNative)
    {
        if (tokensIn > CURVE_SUPPLY - m.curveTokensRemaining) return (0, 0, 0, 0);
        uint256 virtualTokens = m.virtualTokenReserve + tokensIn;
        newVirtualNative = _ceilDiv(invariantK, virtualTokens);
        if (newVirtualNative >= m.virtualNativeReserve) return (0, 0, 0, 0);
        grossNative = m.virtualNativeReserve - newVirtualNative;
        if (grossNative > m.nativeReserve) return (0, 0, 0, 0);
        fee = (grossNative * TRADE_FEE_BPS) / BPS;
        nativeOut = grossNative - fee;
    }

    function _grossForNet(uint256 net) internal pure returns (uint256) {
        return _ceilDiv(net * BPS, BPS - TRADE_FEE_BPS);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        return ((a - 1) / b) + 1;
    }

    function _sendNative(address payable recipient, uint256 amount) internal {
        (bool ok, ) = recipient.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }
}
