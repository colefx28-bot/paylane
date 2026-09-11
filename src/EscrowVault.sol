// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract EscrowVault is EIP712, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public feeSink;

    uint256 public constant TIER_THRESHOLD = 10_000_000; // 10 USDC (6 decimals)
    uint256 public constant FEE_BPS_LOW = 250;           // 2.5%
    uint256 public constant FEE_BPS_HIGH = 100;          // 1.0%
    uint256 public constant BPS_DENOM = 10_000;

    bytes32 public constant DEAL_INTENT_TYPEHASH = keccak256(
        "DealIntent(address buyer,address provider,uint256 amount,bytes32 nonce,uint64 expiry)"
    );

    enum Status { NONE, HELD, SETTLED, REFUNDED }

    struct Deal {
        address buyer;
        address provider;
        uint256 amount;
        uint64 expiry;
        Status status;
    }

    struct DealIntent {
        address buyer;
        address provider;
        uint256 amount;
        bytes32 nonce;
        uint64 expiry;
    }

    mapping(bytes32 => Deal) public deals;

    event Funded(bytes32 indexed dealId, address indexed buyer, address indexed provider, uint256 amount);
    event Settled(bytes32 indexed dealId, address indexed buyer, address indexed provider, uint256 amount, uint256 fee);
    event Released(bytes32 indexed dealId, address indexed provider, uint256 netAmount, uint256 fee);
    event Refunded(bytes32 indexed dealId, address indexed buyer, uint256 amount);
    event FeeSinkUpdated(address indexed oldSink, address indexed newSink);

    constructor(address _usdc, address _feeSink, address _relayerOwner)
        EIP712("A2AEscrowMonopolyEngine", "6")
        Ownable(_relayerOwner)
    {
        require(_usdc != address(0) && _feeSink != address(0), "INVALID_ADDRESS");
        usdc = IERC20(_usdc);
        feeSink = _feeSink;
    }

    function computeFee(uint256 amount) public pure returns (uint256 fee, uint256 net) {
        uint256 bps = amount < TIER_THRESHOLD ? FEE_BPS_LOW : FEE_BPS_HIGH;
        fee = (amount * bps) / BPS_DENOM;
        net = amount - fee;
    }

    function deriveDealId(DealIntent calldata intent) public pure returns (bytes32) {
        return keccak256(abi.encode(intent.buyer, intent.provider, intent.amount, intent.nonce, intent.expiry));
    }

    function _verifyIntent(DealIntent calldata intent, bytes calldata signature) internal view returns (bytes32 dealId) {
        require(intent.buyer != address(0), "ZERO_BUYER");
        require(intent.provider != address(0), "ZERO_PROVIDER");
        require(block.timestamp <= intent.expiry, "EXPIRED");
        require(intent.amount > 0, "ZERO_AMOUNT");

        dealId = deriveDealId(intent);
        require(deals[dealId].status == Status.NONE, "DEAL_EXISTS");

        bytes32 structHash = keccak256(abi.encode(
            DEAL_INTENT_TYPEHASH,
            intent.buyer,
            intent.provider,
            intent.amount,
            intent.nonce,
            intent.expiry
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, signature);
        require(recovered == intent.buyer, "INVALID_SIGNATURE");
    }

    function fundAndSettle(
        DealIntent calldata intent,
        bytes calldata signature
    ) external whenNotPaused nonReentrant returns (bytes32 dealId) {
        dealId = _verifyIntent(intent, signature);
        (uint256 fee, uint256 net) = computeFee(intent.amount);

        deals[dealId] = Deal({
            buyer: intent.buyer,
            provider: intent.provider,
            amount: intent.amount,
            expiry: intent.expiry,
            status: Status.SETTLED
        });

        usdc.safeTransferFrom(intent.buyer, feeSink, fee);
        usdc.safeTransferFrom(intent.buyer, intent.provider, net);

        emit Settled(dealId, intent.buyer, intent.provider, intent.amount, fee);
    }

    function fund(
        DealIntent calldata intent,
        bytes calldata signature
    ) external whenNotPaused nonReentrant returns (bytes32 dealId) {
        dealId = _verifyIntent(intent, signature);

        deals[dealId] = Deal({
            buyer: intent.buyer,
            provider: intent.provider,
            amount: intent.amount,
            expiry: intent.expiry,
            status: Status.HELD
        });

        usdc.safeTransferFrom(intent.buyer, address(this), intent.amount);

        emit Funded(dealId, intent.buyer, intent.provider, intent.amount);
    }

    function release(bytes32 dealId) external onlyOwner nonReentrant {
        Deal storage deal = deals[dealId];
        require(deal.status == Status.HELD, "NOT_HELD");

        deal.status = Status.SETTLED;
        (uint256 fee, uint256 net) = computeFee(deal.amount);

        usdc.safeTransfer(feeSink, fee);
        usdc.safeTransfer(deal.provider, net);

        emit Released(dealId, deal.provider, net, fee);
    }

    function refund(bytes32 dealId) external nonReentrant {
        Deal storage deal = deals[dealId];
        require(deal.status == Status.HELD, "NOT_HELD");
        require(block.timestamp > deal.expiry, "NOT_EXPIRED");

        deal.status = Status.REFUNDED;

        usdc.safeTransfer(deal.buyer, deal.amount);

        emit Refunded(dealId, deal.buyer, deal.amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function renounceOwnership() public view override onlyOwner {
        revert("RENOUNCE_DISABLED");
    }

    function setFeeSink(address newSink) external onlyOwner {
        require(newSink != address(0), "INVALID_ADDRESS");
        emit FeeSinkUpdated(feeSink, newSink);
        feeSink = newSink;
    }
}
