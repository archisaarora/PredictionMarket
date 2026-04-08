// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title OutcomeToken
 * @notice Minimal ERC20 used for YES/NO market shares.
 * @dev The PredictionMarket contract is the only minter/burner.
 */
contract OutcomeToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    address public immutable market;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error NotMarket();
    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    modifier onlyMarket() {
        if (msg.sender != market) revert NotMarket();
        _;
    }

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        market = msg.sender;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();

        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }

        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyMarket {
        if (to == address(0)) revert InvalidAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyMarket {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();

        balanceOf[from] = bal - amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidAddress();

        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();

        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/**
 * @title PredictionMarket
 * @notice Base single-market contract for BNB Chain-style prediction markets.
 * @dev Roles:
 *  - Market Owner & Liquidity Provider: seeds and manages liquidity
 *  - Oracle: resolves YES/NO outcome
 *  - Users: trade YES/NO outcome tokens and redeem winners
 */
contract PredictionMarket {
    enum Outcome {
        Unresolved,
        Yes,
        No
    }

    uint256 private constant FEE_BPS = 30; // 0.30% swap fee
    uint256 private constant BPS_DENOM = 10_000;
    uint256 private constant MINIMUM_LIQUIDITY = 1e6;

    string public marketQuestion;
    uint64 public tradingEndsAt;

    address public immutable marketOwner;
    address public immutable oracle;

    Outcome public resolvedOutcome;
    bool public resolved;

    OutcomeToken public immutable yesToken;
    OutcomeToken public immutable noToken;

    // AMM reserves
    uint256 public yesReserve;
    uint256 public noReserve;
    uint256 public ethReserve;

    // LP accounting (for future checkpoint extensions)
    uint256 public totalLpShares;
    mapping(address => uint256) public lpShares;

    // Resolution/redemption accounting
    uint256 public payoutPool;
    uint256 public winningSupplyAtResolution;

    event InitialLiquiditySeeded(address indexed provider, uint256 ethAmount, uint256 yesAmount, uint256 noAmount);
    event LiquidityAdded(address indexed provider, uint256 ethAmount, uint256 yesAmount, uint256 noAmount, uint256 lpMinted);
    event LiquidityRemoved(address indexed provider, uint256 ethAmount, uint256 yesAmount, uint256 noAmount, uint256 lpBurned);
    event Swapped(address indexed trader, bool buyYes, uint256 ethInOrOut, uint256 sharesInOrOut);
    event MarketResolved(Outcome outcome, uint256 payoutPool, uint256 winningSupplySnapshot);
    event Redeemed(address indexed user, uint256 winningSharesBurned, uint256 ethPayout);

    error NotOwner();
    error NotOracle();
    error InvalidAddress();
    error InvalidTimestamp();
    error InvalidAmount();
    error TradingClosed();
    error TradingStillOpen();
    error AlreadyResolved();
    error NotResolved();
    error SlippageExceeded();
    error NoLiquidity();
    error NotWinningToken();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != marketOwner) revert NotOwner();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert NotOracle();
        _;
    }

    modifier onlyOpenTrading() {
        if (resolved || block.timestamp >= tradingEndsAt) revert TradingClosed();
        _;
    }

    constructor(
        string memory question,
        uint64 _tradingEndsAt,
        address _oracle,
        uint256 initialSharesPerSide
    ) payable {
        if (bytes(question).length == 0) revert InvalidAddress();
        if (_oracle == address(0)) revert InvalidAddress();
        if (_tradingEndsAt <= block.timestamp) revert InvalidTimestamp();
        if (msg.value == 0 || initialSharesPerSide == 0) revert InvalidAmount();

        marketOwner = msg.sender;
        oracle = _oracle;

        marketQuestion = question;
        tradingEndsAt = _tradingEndsAt;

        yesToken = new OutcomeToken("Prediction YES", "pYES");
        noToken = new OutcomeToken("Prediction NO", "pNO");

        yesToken.mint(address(this), initialSharesPerSide);
        noToken.mint(address(this), initialSharesPerSide);

        yesReserve = initialSharesPerSide;
        noReserve = initialSharesPerSide;
        ethReserve = msg.value;

        uint256 seedShares = _sqrt(msg.value * initialSharesPerSide * initialSharesPerSide);
        if (seedShares <= MINIMUM_LIQUIDITY) revert InvalidAmount();

        totalLpShares = seedShares;
        lpShares[msg.sender] = seedShares;

        emit InitialLiquiditySeeded(msg.sender, msg.value, initialSharesPerSide, initialSharesPerSide);
    }

    function addLiquidity(uint256 yesAmount, uint256 noAmount) external payable onlyOwner onlyOpenTrading {
        if (msg.value == 0 || yesAmount == 0 || noAmount == 0) revert InvalidAmount();

        yesToken.transferFrom(msg.sender, address(this), yesAmount);
        noToken.transferFrom(msg.sender, address(this), noAmount);

        uint256 lpMinted = (msg.value * totalLpShares) / ethReserve;
        if (lpMinted == 0) revert InvalidAmount();

        yesReserve += yesAmount;
        noReserve += noAmount;
        ethReserve += msg.value;

        totalLpShares += lpMinted;
        lpShares[msg.sender] += lpMinted;

        emit LiquidityAdded(msg.sender, msg.value, yesAmount, noAmount, lpMinted);
    }

    function removeLiquidity(uint256 lpAmount) external onlyOwner onlyOpenTrading {
        if (lpAmount == 0 || lpShares[msg.sender] < lpAmount) revert InvalidAmount();

        uint256 ethOut = (ethReserve * lpAmount) / totalLpShares;
        uint256 yesOut = (yesReserve * lpAmount) / totalLpShares;
        uint256 noOut = (noReserve * lpAmount) / totalLpShares;

        lpShares[msg.sender] -= lpAmount;
        totalLpShares -= lpAmount;

        ethReserve -= ethOut;
        yesReserve -= yesOut;
        noReserve -= noOut;

        yesToken.transfer(msg.sender, yesOut);
        noToken.transfer(msg.sender, noOut);
        _safeTransferNative(msg.sender, ethOut);

        emit LiquidityRemoved(msg.sender, ethOut, yesOut, noOut, lpAmount);
    }

    function buyYes(uint256 minYesOut) external payable onlyOpenTrading returns (uint256 yesOut) {
        if (msg.value == 0) revert InvalidAmount();
        yesOut = _getAmountOut(msg.value, ethReserve, yesReserve);
        if (yesOut < minYesOut || yesOut == 0) revert SlippageExceeded();

        ethReserve += msg.value;
        yesReserve -= yesOut;

        yesToken.transfer(msg.sender, yesOut);
        emit Swapped(msg.sender, true, msg.value, yesOut);
    }

    function buyNo(uint256 minNoOut) external payable onlyOpenTrading returns (uint256 noOut) {
        if (msg.value == 0) revert InvalidAmount();
        noOut = _getAmountOut(msg.value, ethReserve, noReserve);
        if (noOut < minNoOut || noOut == 0) revert SlippageExceeded();

        ethReserve += msg.value;
        noReserve -= noOut;

        noToken.transfer(msg.sender, noOut);
        emit Swapped(msg.sender, false, msg.value, noOut);
    }

    function sellYes(uint256 yesIn, uint256 minEthOut) external onlyOpenTrading returns (uint256 ethOut) {
        if (yesIn == 0) revert InvalidAmount();

        yesToken.transferFrom(msg.sender, address(this), yesIn);
        ethOut = _getAmountOut(yesIn, yesReserve, ethReserve);
        if (ethOut < minEthOut || ethOut == 0) revert SlippageExceeded();

        yesReserve += yesIn;
        ethReserve -= ethOut;

        _safeTransferNative(msg.sender, ethOut);
        emit Swapped(msg.sender, true, ethOut, yesIn);
    }

    function sellNo(uint256 noIn, uint256 minEthOut) external onlyOpenTrading returns (uint256 ethOut) {
        if (noIn == 0) revert InvalidAmount();

        noToken.transferFrom(msg.sender, address(this), noIn);
        ethOut = _getAmountOut(noIn, noReserve, ethReserve);
        if (ethOut < minEthOut || ethOut == 0) revert SlippageExceeded();

        noReserve += noIn;
        ethReserve -= ethOut;

        _safeTransferNative(msg.sender, ethOut);
        emit Swapped(msg.sender, false, ethOut, noIn);
    }

    function resolveMarket(bool yesWon) external onlyOracle {
        if (resolved) revert AlreadyResolved();
        if (block.timestamp < tradingEndsAt) revert TradingStillOpen();

        resolved = true;
        resolvedOutcome = yesWon ? Outcome.Yes : Outcome.No;

        payoutPool = address(this).balance;
        winningSupplyAtResolution = yesWon ? yesToken.totalSupply() : noToken.totalSupply();

        if (winningSupplyAtResolution == 0 || payoutPool == 0) revert NoLiquidity();

        emit MarketResolved(resolvedOutcome, payoutPool, winningSupplyAtResolution);
    }

    function redeem(uint256 winningTokenAmount) external returns (uint256 ethPayout) {
        if (!resolved) revert NotResolved();
        if (winningTokenAmount == 0) revert InvalidAmount();

        OutcomeToken winner = resolvedOutcome == Outcome.Yes ? yesToken : noToken;
        winner.burn(msg.sender, winningTokenAmount);

        ethPayout = (payoutPool * winningTokenAmount) / winningSupplyAtResolution;
        if (ethPayout == 0) revert InvalidAmount();

        payoutPool -= ethPayout;
        winningSupplyAtResolution -= winningTokenAmount;

        _safeTransferNative(msg.sender, ethPayout);
        emit Redeemed(msg.sender, winningTokenAmount, ethPayout);
    }

    function previewBuyYes(uint256 ethIn) external view returns (uint256) {
        return _getAmountOut(ethIn, ethReserve, yesReserve);
    }

    function previewBuyNo(uint256 ethIn) external view returns (uint256) {
        return _getAmountOut(ethIn, ethReserve, noReserve);
    }

    function previewSellYes(uint256 yesIn) external view returns (uint256) {
        return _getAmountOut(yesIn, yesReserve, ethReserve);
    }

    function previewSellNo(uint256 noIn) external view returns (uint256) {
        return _getAmountOut(noIn, noReserve, ethReserve);
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256 out) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;

        uint256 amountInWithFee = amountIn * (BPS_DENOM - FEE_BPS);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * BPS_DENOM) + amountInWithFee;
        out = numerator / denominator;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _safeTransferNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
