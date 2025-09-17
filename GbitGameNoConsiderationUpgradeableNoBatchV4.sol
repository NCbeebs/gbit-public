// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// Custom error declarations
error GameCompletedError();
error InvalidPositionError();
error PositionTakenError();
error GameFullError();
error FeeTransferFailedError();
error NotEnoughPositionsError();
error NotEnoughTicketsError();
error InvalidQuantityError();
error InvalidTicketError();
error NotOwnerError();
error ApprovalRequiredError();
error NotListedError();
error TicketInactiveError();
error DealerFeeTransferFailedError();
error SellerPaymentFailedError();
error CantOfferOnOwnTicketError();
error SendETHWithOfferError();
error OfferExistsError();
error AlreadyListedError();
error NoValidOfferError();
error NoOfferError();
error NotOfferMakerError();
error RoundActiveError();
error GameNotCompletedError();
error NoActiveRoundError();
error NoRandomWordsError();
error InvalidWinnerError();
error TokenDoesNotExistError();
error NoFundsToWithdrawError();
error WithdrawalFailedError();
error FunctionNotFoundError();
// VRF Failure Recovery Errors
error RequestNotStaleError();
error NoPendingRequestError();
// Claiming system errors
error ClaimLimitExceededError();
// VRF Adapter errors
error NotVRFAdapterError();
error PendingAdapterNotSetError();
error StaleRandomnessError();
error ListingPriceZeroError();
error IncorrectPaymentError();
error WrongVRFRequestError();
error RerequestNotAllowedError();
// Validation errors - RESTORED FOR V4 STANDALONE DEPLOYMENT
// error FeeTooHighError(); // COMMENTED OUT - validation logic removed for size optimization
// error PrizeTooHighError(); // COMMENTED OUT - validation logic removed for size optimization
// error RolloverTooHighError(); // COMMENTED OUT - validation logic removed for size optimization
error TimeoutTooShortError();
error InvalidDealerAddressError();
// Batched elimination errors
error NotEliminatingError();
error EliminationInProgressError();

interface IGbitVRFAdapter {
    function requestRandomness() external returns (uint256 requestId);
}

interface IGbitGameRandomReceiver {
    function receiveRandomness(uint256 requestId, uint256[] calldata randomWords) external;
}

contract GbitGameNoConsiderationUpgradeableNoBatchV4 is
    Initializable,
    ERC721Upgradeable,
    OwnableUpgradeable,
    AutomationCompatibleInterface,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IGbitGameRandomReceiver
{
    using Strings for uint256;

    // -------------- Constants --------------
    uint8 public constant MAX_PAST_WINNERS = 10;

    // -------------- Configurable State Variables --------------
    address payable public dealerAddress;
    uint256 public secondaryMarketFeePercent;
    uint256 public prizePoolPercent;
    uint256 public rolloverFeePercent;
    uint256 public vrfTimeout;

    // Bitfield types
    uint8 private constant BF_ACTIVE = 0;
    uint8 private constant BF_LISTED = 1;
    uint8 private constant BF_OFFER = 2;
    uint8 private constant BF_WINNER = 3;
    uint8 private constant NUM_BITFIELDS = 4;

    // Game state bit flags
    uint8 private constant GAME_STATE_ROUND_ACTIVE = 1;    // 00000001
    uint8 private constant GAME_STATE_COMPLETED = 2;       // 00000010
    uint8 private constant GAME_STATE_FINALIZING = 4;      // 00000100
    uint8 private constant GAME_STATE_ELIMINATING = 8;     // 00001000

    // -------------- State Variables --------------
    string private _baseTokenURI; // ADDED FOR OFF-CHAIN METADATA
    uint256 private _nextTokenId; // ADDED FOR ERC721
    uint256 public totalTickets; // default set in initialize
    uint256 public currentGameId;
    uint256 public currentRound;
    uint8 private _gameState; // packed flags
    uint256 public roundEndTime;
    uint256 public roundDuration; // adjustable
    uint256 public winningTicketId;

    // Prize pool tracking
    uint256 private _prizePool;
    uint256 private s_pendingRollover;
    mapping(uint256 => bool) private _isWinnerToken;

    // Active tickets counter
    uint256 private _activeTicketCount;
    uint256 public currentGameMinted;

    // VRF via adapter
    address public vrfAdapter;
    address public pendingVrfAdapter;
    uint256 public lastRequestId;
    mapping(uint256 => uint256) private _requestRound; // requestId => roundId

    // VRF Failure Recovery
    uint256 public vrfRequestTimestamp;

    // Game finalization
    uint256 private _processingCheckpoint;

    // Pull Payment Pattern
    mapping(address => uint256) private _pendingWithdrawals;

    // Position/TokenID mapping
    mapping(uint256 => uint256) private _positionToTokenId;
    mapping(uint256 => uint256) private _tokenIdToPosition;

    // NEW: Per-game claim limit
    struct ClaimCounter { uint32 gameId; uint32 count; }
    mapping(address => ClaimCounter) private _claimCounters;
    address[] private _currentGameClaimers;
    uint256 public maxClaimsPerAccount;

    // -------------- Hybrid Data Structure --------------
    uint256[][] private _bitfields; // bitfields for flags

    struct TicketData {
        uint32 gameId;
        uint32 creationTime;
        uint256 listingPrice;
        uint256 offerAmount;
        address offerMaker;
    }
    mapping(uint256 => TicketData) private _tickets;

    // Winners array - limited to the 10 most recent winners
    uint256[] public pastWinners;

    // -------------- Elimination Process State --------------
    uint256 private _eliminationRandomSeed;        // Random seed for elimination process
    uint256 private _eliminationCheckpoint;       // Current position in elimination batch
    uint256 private _eliminationBatchSize;        // Size of elimination batches
    uint256 private _eliminationTotalCount;       // Total tickets to eliminate
    uint256 private _eliminationTargetCount;      // Target tickets to eliminate

    // -------------- Array Building State --------------
    uint256 private _arrayBuildingCheckpoint;     // Current position in array building
    bool private _arrayBuildingComplete;          // Whether array building is complete
    uint256[] private _ticketsToEliminate;        // Dynamic array of tickets to eliminate

    // ===== GAS TRACKING VARIABLES (REMOVE BEFORE PRODUCTION DEPLOYMENT) =====
    // uint256 private _eliminationBatchCounter;
    // uint256 private _eliminationTotalGasUsed;
    // uint256 private _arrayBuildingBatchCounter;
    // uint256 private _arrayBuildingTotalGasUsed;
    // ===== END GAS TRACKING VARIABLES =====

    // -------------- Events --------------
    // Claiming
    event TicketsClaimed(address indexed claimer, uint256[] positions, uint256 remaining);
    event AccountClaimLimitUpdated(address indexed account, uint256 newCount, uint256 maxAllowed);
    event PrizePoolContribution(uint256 indexed position, uint256 amount, string source);
    // External seeding
    event PrizePoolSeeded(address indexed seeder, uint256 amount);
    // ADDED FOR EIP-4906 COMPATIBILITY
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    // Game
    event RoundStarted(uint256 indexed roundNumber, uint256 endTime);
    event RoundEnded(uint256 indexed roundNumber, uint256 ticketsRemaining);
    event EliminationSummary(uint256 indexed roundNumber, uint256 ticketsEliminated, uint256 remainingTickets);
    
    // ===== GAS TRACKING EVENTS (REMOVE BEFORE PRODUCTION DEPLOYMENT) =====
    // event ArrayBuildingBatch(uint256 indexed roundNumber, uint256 batchNumber, uint256 startPos, uint256 endPos, uint256 ticketsFound, uint256 gasUsed);
    // event EliminationInitialization(uint256 indexed roundNumber, uint256 totalTickets, uint256 targetEliminations, uint256 gasUsed);
    // event EliminationBatch(uint256 indexed roundNumber, uint256 batchNumber, uint256 startPos, uint256 endPos, uint256 ticketsProcessed, uint256 gasUsed);
    // event EliminationPhaseComplete(uint256 indexed roundNumber, uint256 totalBatches, uint256 totalGasUsed, uint256 ticketsEliminated);
    // ===== END GAS TRACKING EVENTS =====
    
    event WinnerDeclared(uint256 indexed position, address owner);
    event GameFinalized(uint256 winningPosition);
    event GameStarted(uint256 indexed gameId, uint256 totalTickets);
    event WinnerPaymentDeferred(uint256 indexed position, address indexed winner, uint256 amount);

    // Marketplace
    event TicketListed(uint256 indexed position, uint256 price);
    event TicketUnlisted(uint256 indexed position);
    event TicketSold(uint256 indexed position, address seller, address buyer, uint256 price);
    event OfferMade(uint256 indexed position, address indexed buyer, uint256 amount);
    event OfferAccepted(uint256 indexed position, address indexed seller, address indexed buyer, uint256 amount);
    event OfferRejected(uint256 indexed position, address indexed buyer, uint256 amount);
    event OfferCanceled(uint256 indexed position, address indexed buyer, uint256 amount);
    event SecondaryMarketCleared(uint256 indexed roundNumber, bool listingsCleared, bool offersCanceled);

    // Randomness events
    event RandomnessReceived(uint256 indexed requestId, uint256 randomSeed);

    // Pull payments
    event WithdrawalComplete(address indexed payee, uint256 amount);
    event FailedRefund(address indexed recipient, uint256 amount, string reason);
    // Emergency withdrawal
    event EmergencyWithdrawal(address indexed owner, uint256 amount, uint256 remainingPrizePool, uint256 remainingRollover);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address initialOwner,
        uint256 initialTotalTickets,
        uint256 initialRoundDuration,
        uint256 initialMaxClaimsPerAccount
    ) public initializer {
        // Call parent initializers in the correct order
        __ERC721_init(name_, symbol_);
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        
        if (initialOwner != address(0) && initialOwner != msg.sender) {
            _transferOwnership(initialOwner);
        }

        totalTickets = initialTotalTickets;
        if (totalTickets == 0) totalTickets = 256;
        currentGameId = 1;
        roundDuration = initialRoundDuration;
        maxClaimsPerAccount = initialMaxClaimsPerAccount;
        if (maxClaimsPerAccount == 0) maxClaimsPerAccount = 1;
        _nextTokenId = 1;

        // Set initial values for configurable variables
        dealerAddress = payable(0x86127BaBa33Abc82598448340F9B99Cb546f07Fe);
        secondaryMarketFeePercent = 5; // 5%
        prizePoolPercent = 10; // 10%
        rolloverFeePercent = 10; // 10%
        vrfTimeout = 24 hours;
        _eliminationBatchSize = 30; // Default batch size for elimination processing

        _initBitfields(totalTickets);
    }

    // -------------- ERC721 Overrides --------------
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
        
        // Clear marketplace state when transferring between non-zero addresses
        if (to != address(0) && from != address(0)) {
            uint256 position = _tokenIdToPosition[tokenId];
            if (position != 0) {
                // Clear listing if exists
                if (isListed(position)) {
                    _setBit(BF_LISTED, position, false);
                    _tickets[position].listingPrice = 0;
                    emit TicketUnlisted(position);
                }
                
                // Clear offers if exists
                if (hasOffer(position)) {
                    _refundOffer(position);
                }
            }
        }
        
        // Clear active bit when burning (existing logic)
        if (to == address(0)) {
            if (_exists(tokenId)) {
                uint256 position = _tokenIdToPosition[tokenId];
                if (position != 0 && isActive(position)) {
                    _setBit(BF_ACTIVE, position, false);
                }
            }
        }
    }

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal virtual override {
        super._afterTokenTransfer(from, to, tokenId, batchSize);
        if (to != address(0) && !gameCompleted()) {
            if (_exists(tokenId)) {
                _approve(address(this), tokenId);
            }
        }
    }

    // -------------- Core Bitfield Operations --------------
    function _initBitfields(uint256 _totalTickets) internal {
        uint256 requiredWords = (_totalTickets == 0) ? 0 : ((_totalTickets - 1) / 256) + 1;
        _bitfields = new uint256[][](NUM_BITFIELDS);
        for (uint8 i = 0; i < NUM_BITFIELDS; i++) {
            _bitfields[i] = new uint256[](requiredWords);
        }
        _activeTicketCount = 0;
    }

    function _setBit(uint8 fieldType, uint256 position, bool value) internal {
        uint256 bitPosition = position - 1;
        uint256 wordIndex = bitPosition / 256;
        uint256 bitOffset = bitPosition % 256;
        bool currentValue = (_bitfields[fieldType][wordIndex] & (1 << bitOffset)) != 0;
        if (value) {
            _bitfields[fieldType][wordIndex] |= (1 << bitOffset);
            if (fieldType == BF_ACTIVE && !currentValue) {
                _activeTicketCount++;
            }
        } else {
            _bitfields[fieldType][wordIndex] &= ~(1 << bitOffset);
            if (fieldType == BF_ACTIVE && currentValue) {
                _activeTicketCount--;
            }
        }
    }

    function _getBit(uint8 fieldType, uint256 position) internal view returns (bool) {
        uint256 bitPosition = position - 1;
        uint256 wordIndex = bitPosition / 256;
        uint256 bitOffset = bitPosition % 256;
        if (wordIndex >= _bitfields[fieldType].length) return false;
        return (_bitfields[fieldType][wordIndex] & (1 << bitOffset)) != 0;
    }

    function _getActiveTickets() internal view returns (uint256[] memory) {
        uint256[] memory activeTickets = new uint256[](_activeTicketCount);
        if (_activeTicketCount == 0) return activeTickets;
        uint256 index = 0;
        for (uint256 wordIdx = 0; wordIdx < _bitfields[BF_ACTIVE].length && index < _activeTicketCount; wordIdx++) {
            uint256 word = _bitfields[BF_ACTIVE][wordIdx];
            uint256 bitBase = wordIdx * 256;
            while (word > 0 && index < _activeTicketCount) {
                uint256 bitPos = _findLSBPosition(word);
                activeTickets[index++] = bitBase + bitPos + 1;
                word &= ~(1 << bitPos);
            }
        }
        return activeTickets;
    }

    function _findLSBPosition(uint256 value) internal pure returns (uint256) {
        uint256 position = 0;
        if (value == 0) return 0;
        while ((value & 1) == 0) {
            value >>= 1;
            position++;
        }
        return position;
    }

    // -------------- Public Status Helpers --------------
    function isActive(uint256 position) public view returns (bool) { return _getBit(BF_ACTIVE, position); }
    function isListed(uint256 position) public view returns (bool) { return _getBit(BF_LISTED, position); }
    function hasOffer(uint256 position) public view returns (bool) { return _getBit(BF_OFFER, position); }

    function isWinner(uint256 position) external view returns (bool) {
        bool bitfieldResult = _getBit(BF_WINNER, position);
        if (!bitfieldResult) {
            uint256 tokenId = _positionToTokenId[position];
            if (tokenId != 0) {
                return _isWinnerToken[tokenId];
            }
        }
        return bitfieldResult;
    }

    function getActiveTicketCount() external view returns (uint256) { return _activeTicketCount; }
    function getActiveTickets() public view returns (uint256[] memory) { return _getActiveTickets(); }
    function getWinners() external view returns (uint256[] memory) { return pastWinners; }

    // -------------- Ticket Claiming (Free) --------------
    function claim(uint256 position) external nonReentrant whenNotPaused {
        if (gameCompleted()) revert GameCompletedError();
        if (position < 1 || position > totalTickets) revert InvalidPositionError();
        if (isActive(position)) revert PositionTakenError();
        if (currentGameMinted >= totalTickets) revert GameFullError();

        ClaimCounter storage counter = _claimCounters[msg.sender];
        if (counter.gameId != uint32(currentGameId)) {
            counter.gameId = uint32(currentGameId);
            counter.count = 0;
            _currentGameClaimers.push(msg.sender);
        }
        if (counter.count >= maxClaimsPerAccount) revert ClaimLimitExceededError();

        counter.count++;
        _mintTicket(position, msg.sender);
        emit AccountClaimLimitUpdated(msg.sender, counter.count, maxClaimsPerAccount);
    }

    function _mintTicket(uint256 position, address recipient) internal {
        uint256 tokenId = _nextTokenId;
        _nextTokenId++;

        currentGameMinted++;
        _setBit(BF_ACTIVE, position, true);
        _mint(recipient, tokenId);
        
        _positionToTokenId[position] = tokenId;
        _tokenIdToPosition[tokenId] = position;
        _tickets[position] = TicketData({
            gameId: uint32(currentGameId),
            creationTime: uint32(block.timestamp),
            listingPrice: 0,
            offerAmount: 0,
            offerMaker: address(0)
        });
        _approve(address(this), tokenId);
        
        // For single ticket claims, create array with one position
        uint256[] memory positions = new uint256[](1);
        positions[0] = position;
        emit TicketsClaimed(recipient, positions, totalTickets - currentGameMinted);
        
        if (currentGameMinted == totalTickets && !roundActive()) {
            _startRound();
        }
    }

    // -------------- Marketplace Operations --------------
    function list(uint256 position, uint256 price) external whenNotPaused {
        uint256 tokenId = _positionToTokenId[position];
        if (!_exists(tokenId) || !isActive(position)) revert InvalidTicketError();
        if (ownerOf(tokenId) != msg.sender) revert NotOwnerError();
        if (price == 0) revert ListingPriceZeroError();
        if (getApproved(tokenId) != address(this) && !isApprovedForAll(msg.sender, address(this)))
            revert ApprovalRequiredError();
        _setBit(BF_LISTED, position, true);
        _tickets[position].listingPrice = price;
        emit TicketListed(position, price);
    }

    function unlist(uint256 position) external whenNotPaused {
        uint256 tokenId = _positionToTokenId[position];
        if (!_exists(tokenId) || !isListed(position)) revert NotListedError();
        if (ownerOf(tokenId) != msg.sender) revert NotOwnerError();
        _setBit(BF_LISTED, position, false);
        _tickets[position].listingPrice = 0;
        emit TicketUnlisted(position);
    }

    function purchase(uint256 position) external payable nonReentrant whenNotPaused {
        if (!isListed(position)) revert NotListedError();
        if (!isActive(position)) revert TicketInactiveError();
        if (msg.value != _tickets[position].listingPrice) revert IncorrectPaymentError();
        uint256 tokenId = _positionToTokenId[position];
        address seller = ownerOf(tokenId);
        uint256 listingPrice = _tickets[position].listingPrice;
        _setBit(BF_LISTED, position, false);
        _tickets[position].listingPrice = 0;
        emit TicketUnlisted(position);
        if (hasOffer(position)) {
            address offerMaker = _tickets[position].offerMaker;
            uint256 offerAmount = _tickets[position].offerAmount;
            _setBit(BF_OFFER, position, false);
            _tickets[position].offerMaker = address(0);
            _tickets[position].offerAmount = 0;
            _recordPendingWithdrawal(offerMaker, offerAmount, "Offer refund on ticket purchase");
            emit OfferCanceled(position, offerMaker, offerAmount);
        }
        uint256 dealerFee = (listingPrice * secondaryMarketFeePercent) / 100;
        uint256 prizeContribution = (listingPrice * prizePoolPercent) / 100;
        uint256 sellerProceeds = listingPrice - dealerFee - prizeContribution;
        _prizePool += prizeContribution;
        (bool feeSent, ) = dealerAddress.call{value: dealerFee}("");
        if (!feeSent) revert DealerFeeTransferFailedError();
        // SECURITY NOTE: The following is a "push" payment. While the `nonReentrant`
        // modifier protects against re-entrancy, this call could still fail if the `seller`
        // is a contract that cannot accept Ether or intentionally reverts, leading to
        // denial-of-service for this specific ticket sale. A pull-payment pattern is a safer alternative. 
        //For now, assuming this is not a problem due to desire to sell tickets before elimination.
        (bool sent, ) = payable(seller).call{value: sellerProceeds}("");
        if (!sent) revert SellerPaymentFailedError();
        this.safeTransferFrom(seller, msg.sender, tokenId);
        emit TicketSold(position, seller, msg.sender, listingPrice);
        emit PrizePoolContribution(position, prizeContribution, "listing_purchase");
    }

    function makeOffer(uint256 position) external payable nonReentrant whenNotPaused {
        uint256 tokenId = _positionToTokenId[position];
        if (!_exists(tokenId) || !isActive(position)) revert InvalidTicketError();
        if (ownerOf(tokenId) == msg.sender) revert CantOfferOnOwnTicketError();
        if (msg.value == 0) revert SendETHWithOfferError();
        if (hasOffer(position)) revert OfferExistsError();
        _setBit(BF_OFFER, position, true);
        _tickets[position].offerMaker = msg.sender;
        _tickets[position].offerAmount = msg.value;
        emit OfferMade(position, msg.sender, msg.value);
    }

//Seller could reject ETH and DOS the ticket.
    function acceptOffer(uint256 position) external nonReentrant whenNotPaused {
        uint256 tokenId = _positionToTokenId[position];
        if (!_exists(tokenId) || !hasOffer(position)) revert NoValidOfferError();
        if (!isActive(position)) revert TicketInactiveError();
        if (ownerOf(tokenId) != msg.sender) revert NotOwnerError();
        address buyer = _tickets[position].offerMaker;
        uint256 offerAmount = _tickets[position].offerAmount;
        uint256 dealerFee = (offerAmount * secondaryMarketFeePercent) / 100;
        uint256 prizeContribution = (offerAmount * prizePoolPercent) / 100;
        uint256 sellerProceeds = offerAmount - dealerFee - prizeContribution;
        _setBit(BF_OFFER, position, false);
        _tickets[position].offerMaker = address(0);
        _tickets[position].offerAmount = 0;
        if (isListed(position)) {
            _setBit(BF_LISTED, position, false);
            _tickets[position].listingPrice = 0;
        }
        _prizePool += prizeContribution;
        this.safeTransferFrom(msg.sender, buyer, tokenId);
        (bool feeSent, ) = dealerAddress.call{value: dealerFee}("");
        if (!feeSent) revert DealerFeeTransferFailedError();
        (bool sent, ) = payable(msg.sender).call{value: sellerProceeds}("");
        if (!sent) revert SellerPaymentFailedError();
        emit OfferAccepted(position, msg.sender, buyer, offerAmount);
        emit PrizePoolContribution(position, prizeContribution, "offer_acceptance");
    }

    function rejectOffer(uint256 position) external nonReentrant whenNotPaused {
        uint256 tokenId = _positionToTokenId[position];
        if (!_exists(tokenId) || !hasOffer(position)) revert NoOfferError();
        if (ownerOf(tokenId) != msg.sender) revert NotOwnerError();
        _refundOffer(position);
        emit OfferRejected(position, _tickets[position].offerMaker, _tickets[position].offerAmount);
    }

    function cancelOffer(uint256 position) external nonReentrant whenNotPaused {
        if (!hasOffer(position)) revert NoOfferError();
        if (_tickets[position].offerMaker != msg.sender) revert NotOfferMakerError();
        _refundOffer(position);
        emit OfferCanceled(position, msg.sender, _tickets[position].offerAmount);
    }

    function _refundOffer(uint256 position) internal {
        address buyer = _tickets[position].offerMaker;
        uint256 amount = _tickets[position].offerAmount;
        _setBit(BF_OFFER, position, false);
        _tickets[position].offerMaker = address(0);
        _tickets[position].offerAmount = 0;
        (bool sent, ) = payable(buyer).call{value: amount}("");
        if (!sent) {
            _recordPendingWithdrawal(buyer, amount, "Failed direct offer refund");
            emit FailedRefund(buyer, amount, "Offer refund");
        }
    }

    // -------------- Round Management --------------
    function startRound() external onlyOwner whenNotPaused { _startRound(); }

    function _startRound() internal whenNotPaused {
        if (roundActive()) revert RoundActiveError();
        if (gameCompleted()) revert GameCompletedError();
        currentRound++;
        roundEndTime = block.timestamp + roundDuration;
        _gameState |= GAME_STATE_ROUND_ACTIVE;
        emit RoundStarted(currentRound, roundEndTime);
    }

    function endRound() internal whenNotPaused {
        if (!roundActive()) revert NoActiveRoundError();
        _gameState &= ~GAME_STATE_ROUND_ACTIVE;
        _clearAllMarket();
        if (vrfAdapter == address(0)) revert PendingAdapterNotSetError();
        lastRequestId = IGbitVRFAdapter(vrfAdapter).requestRandomness();
        _requestRound[lastRequestId] = currentRound;
        
        vrfRequestTimestamp = block.timestamp;
        uint256 ticketsRemaining = _activeTicketCount;
        emit RoundEnded(currentRound, ticketsRemaining);
    }

    function _clearAllMarket() internal {
        bool hasOffers = false;
        for (uint256 wordIdx = 0; wordIdx < _bitfields[BF_OFFER].length; wordIdx++) {
            uint256 word = _bitfields[BF_OFFER][wordIdx];
            if (word == 0) continue;
            hasOffers = true;
            uint256 bitBase = wordIdx * 256;
            while (word > 0) {
                uint256 bitPos = _findLSBPosition(word);
                uint256 position = bitBase + bitPos + 1;
                TicketData storage ticketData = _tickets[position];
                if (ticketData.offerAmount > 0 && ticketData.offerMaker != address(0)) {
                    _recordPendingWithdrawal(ticketData.offerMaker, ticketData.offerAmount, "Round ended - offer refund");
                    ticketData.offerMaker = address(0);
                    ticketData.offerAmount = 0;
                }
                word &= ~(1 << bitPos);
            }
            _bitfields[BF_OFFER][wordIdx] = 0;
        }
        bool hasListings = false;
        for (uint256 i = 0; i < _bitfields[BF_LISTED].length; i++) {
            if (_bitfields[BF_LISTED][i] != 0) {
                hasListings = true;
                _bitfields[BF_LISTED][i] = 0;
            }
        }
        
        if (hasOffers || hasListings) {
            emit SecondaryMarketCleared(currentRound, hasListings, hasOffers);
        }
    }

    // -------------- Randomness Handling --------------
    function receiveRandomness(uint256 requestId, uint256[] calldata randomWords) external nonReentrant {
        if (msg.sender != vrfAdapter) revert NotVRFAdapterError();
        if (randomWords.length == 0) revert NoRandomWordsError();
        if (requestId != lastRequestId) revert WrongVRFRequestError();
        
        // Check if randomness is stale
        if (_requestRound[requestId] != currentRound) revert StaleRandomnessError();
        
        // Store the random seed and set game state to ELIMINATING
        _eliminationRandomSeed = randomWords[0];
        _gameState |= GAME_STATE_ELIMINATING;
        
        // Emit event to confirm randomness was received
        emit RandomnessReceived(requestId, randomWords[0]);
    }

    // -------------- Elimination Logic --------------
    // Optimized batched elimination processing function with batched array building
    function processElimination() public whenNotPaused {
        // Validate game state
        if (!((_gameState & GAME_STATE_ELIMINATING) != 0)) revert NotEliminatingError();
        
        // Phase 1: Batched array building (if not complete)
        if (!_arrayBuildingComplete) {
            _buildTicketArrayBatch();
            return; // Exit after building batch
        }
        
        // Phase 2: Elimination processing (existing Fisher-Yates logic)
        bool justInitialized = false;

        // First-time initialization: set up elimination parameters
        if (_eliminationTotalCount == 0) {
            // ===== GAS TRACKING: ELIMINATION INITIALIZATION START (REMOVE BEFORE PRODUCTION) =====
            // uint256 gasStart = gasleft();
            // ===== END GAS TRACKING =====
            
            _eliminationTotalCount = _ticketsToEliminate.length;
            _eliminationTargetCount = _eliminationTotalCount / 2;
            
            // ===== GAS TRACKING: ELIMINATION INITIALIZATION COMPLETE (REMOVE BEFORE PRODUCTION) =====
            // uint256 gasUsed = gasStart - gasleft();
            // emit EliminationInitialization(currentRound, _eliminationTotalCount, _eliminationTargetCount, gasUsed);
            // _eliminationBatchCounter = 0;
            // _eliminationTotalGasUsed = gasUsed;
            // ===== END GAS TRACKING =====
            
            // If there are no tickets or only one, we can resolve it immediately as it's cheap.
            if (_eliminationTotalCount <= 1) {
                if (_eliminationTotalCount == 1) {
                    _declareWinner(_ticketsToEliminate[0]);
                }
                _cleanupElimination();
                return; // Exit completely
            }
            
            justInitialized = true;
        }
        
        // If initialization just happened in this transaction, exit.
        // This splits the heavy gas cost of initialization from the first batch processing.
        // The next performUpkeep call will handle the first batch.
        if (justInitialized) {
            return;
        }
        
        // Handle edge cases for subsequent calls (should not happen if init logic is correct)
        if (_eliminationTotalCount <= 1) {
            if (_eliminationTotalCount == 1 && _ticketsToEliminate.length > 0) {
                _declareWinner(_ticketsToEliminate[0]);
            }
            _cleanupElimination();
            return;
        }
        
        // Calculate end position for this batch
        uint256 batchEnd = _eliminationCheckpoint + _eliminationBatchSize;
        if (batchEnd > _eliminationTargetCount) {
            batchEnd = _eliminationTargetCount;
        }
        
        // ===== GAS TRACKING: ELIMINATION BATCH START (REMOVE BEFORE PRODUCTION) =====
        // uint256 batchGasStart = gasleft();
        // _eliminationBatchCounter++;
        // uint256 batchStartPos = _eliminationCheckpoint;
        // ===== END GAS TRACKING =====
        
        // Process this batch of eliminations
        for (uint256 i = _eliminationCheckpoint; i < batchEnd; i++) {
            // Fisher-Yates shuffle step
            uint256 j = i + (uint256(keccak256(abi.encode(_eliminationRandomSeed, i))) % (_eliminationTotalCount - i));
            
            // Swap if needed
            if (i != j) {
                (_ticketsToEliminate[i], _ticketsToEliminate[j]) = (_ticketsToEliminate[j], _ticketsToEliminate[i]);
            }
            
            // Eliminate the ticket
            _setBit(BF_ACTIVE, _ticketsToEliminate[i], false);
        }
        
        // Update checkpoint
        _eliminationCheckpoint = batchEnd;
        
        // ===== GAS TRACKING: ELIMINATION BATCH COMPLETE (REMOVE BEFORE PRODUCTION) =====
        // uint256 batchGasUsed = batchGasStart - gasleft();
        // _eliminationTotalGasUsed += batchGasUsed;
        // uint256 ticketsProcessed = batchEnd - batchStartPos;
        // emit EliminationBatch(currentRound, _eliminationBatchCounter, batchStartPos, batchEnd, ticketsProcessed, batchGasUsed);
        // ===== END GAS TRACKING =====
        
        // Check if elimination process is complete
        if (_eliminationCheckpoint >= _eliminationTargetCount) {
            // ===== GAS TRACKING: PHASE COMPLETE (REMOVE BEFORE PRODUCTION) =====
            // emit EliminationPhaseComplete(currentRound, _eliminationBatchCounter, _eliminationTotalGasUsed, _eliminationTargetCount);
            // ===== END GAS TRACKING =====
            
            emit EliminationSummary(currentRound, _eliminationTargetCount, _activeTicketCount);
            
            // Check if only one ticket remains
            if (_activeTicketCount == 1) {
                // Find and declare the winner
                uint256[] memory remainingTickets = _getActiveTickets();
                if (remainingTickets.length > 0) {
                    _declareWinner(remainingTickets[0]);
                }
            } else if (_activeTicketCount > 1) {
                // Start a new round
                _startRound();
            }
            
            // Clean up elimination state variables
            _cleanupElimination();
        }
    }

    // NEW: Batched array building function for gas efficiency
    function _buildTicketArrayBatch() internal {
        uint256 batchSize = 100; // Process 100 positions per batch
        uint256 startPos = _arrayBuildingCheckpoint;
        uint256 endPos = startPos + batchSize;
        
        if (endPos > totalTickets) {
            endPos = totalTickets;
        }
        
        // ===== GAS TRACKING: ARRAY BUILDING BATCH START (REMOVE BEFORE PRODUCTION) =====
        // uint256 batchGasStart = gasleft();
        // _arrayBuildingBatchCounter++;
        // uint256 ticketsFoundBefore = _ticketsToEliminate.length;
        // ===== END GAS TRACKING =====
        
        // Build array incrementally
        for (uint256 pos = startPos; pos < endPos; pos++) {
            if (isActive(pos + 1)) { // +1 because positions are 1-indexed
                _ticketsToEliminate.push(pos + 1);
            }
        }
        
        _arrayBuildingCheckpoint = endPos;
        
        // ===== GAS TRACKING: ARRAY BUILDING BATCH COMPLETE (REMOVE BEFORE PRODUCTION) =====
        // uint256 batchGasUsed = batchGasStart - gasleft();
        // _arrayBuildingTotalGasUsed += batchGasUsed;
        // uint256 ticketsFound = _ticketsToEliminate.length - ticketsFoundBefore;
        // emit ArrayBuildingBatch(currentRound, _arrayBuildingBatchCounter, startPos, endPos, ticketsFound, batchGasUsed);
        // ===== END GAS TRACKING =====
        
        if (endPos >= totalTickets) {
            _arrayBuildingComplete = true;
        }
    }

    // Helper function to clean up elimination state
    function _cleanupElimination() internal {
        // Clear elimination state
        delete _ticketsToEliminate;
        _gameState &= ~GAME_STATE_ELIMINATING;
        _eliminationCheckpoint = 0;
        _eliminationTotalCount = 0;
        _eliminationTargetCount = 0;
        _eliminationRandomSeed = 0;
        // NEW: Reset array building state
        _arrayBuildingCheckpoint = 0;
        _arrayBuildingComplete = false;
        
        // ===== GAS TRACKING: RESET COUNTERS (REMOVE BEFORE PRODUCTION) =====
        // _arrayBuildingBatchCounter = 0;
        // _eliminationBatchCounter = 0;
        // _arrayBuildingTotalGasUsed = 0;
        // _eliminationTotalGasUsed = 0;
        // ===== END GAS TRACKING =====
    }
    
    // Manual elimination function for emergencies
    function manualProcessElimination() external onlyOwner whenNotPaused {
        processElimination();
    }

    // Manual round ending function for emergencies
    function manualEndRound() external onlyOwner whenNotPaused {
        if (block.timestamp < roundEndTime) revert RoundActiveError();
        endRound();
    }

    function _declareWinner(uint256 position) internal {
        uint256 tokenId = _positionToTokenId[position];
        if (!_exists(tokenId) || !isActive(position)) revert InvalidWinnerError();
        address winner = ownerOf(tokenId);
        uint256 prize = _prizePool;
        bool isContract = winner.code.length > 0;
        uint256 rolloverAmount = (prize * rolloverFeePercent) / 100;
        uint256 winnerPayout = prize - rolloverAmount;
        s_pendingRollover = rolloverAmount;
        winningTicketId = position;
        _setBit(BF_WINNER, position, true);
        _isWinnerToken[tokenId] = true;
        if (pastWinners.length >= MAX_PAST_WINNERS) {
            for (uint i = 0; i < pastWinners.length - 1; i++) { pastWinners[i] = pastWinners[i + 1]; }
            pastWinners.pop();
        }
        pastWinners.push(position);
        _gameState |= GAME_STATE_COMPLETED;
        _prizePool = 0;
        emit WinnerDeclared(position, winner);
        if (isContract) {
            _recordPendingWithdrawal(winner, winnerPayout, "Contract winner payout");
            emit WinnerPaymentDeferred(position, winner, winnerPayout);
        } else {
            (bool sent, ) = payable(winner).call{value: winnerPayout}("");
            if (!sent) {
                _recordPendingWithdrawal(winner, winnerPayout, "Failed winner payout");
                emit WinnerPaymentDeferred(position, winner, winnerPayout);
            }
        }
    }

    // -------------- Game Finalization --------------
    function finalizeGame() public whenNotPaused {
        if (!gameCompleted()) revert GameNotCompletedError();
        uint256 chunkSize = 50;
        if (!((_gameState & GAME_STATE_FINALIZING) != 0)) {
            _gameState |= GAME_STATE_FINALIZING;
            _processingCheckpoint = 1;
        }
        uint256 endPosition = (_processingCheckpoint + chunkSize) < totalTickets ? (_processingCheckpoint + chunkSize) : totalTickets;
        for (uint256 pos = _processingCheckpoint; pos <= endPosition; pos++) {
            uint256 tokenId = _positionToTokenId[pos];
            if (tokenId != 0 && _exists(tokenId)) {
                uint32 tokenGameId = _tickets[pos].gameId;
                if (tokenGameId == currentGameId && pos != winningTicketId) {
                    _burn(tokenId);
                    delete _tokenIdToPosition[tokenId];
                    delete _positionToTokenId[pos];
                    delete _tickets[pos];
                }
            }
        }
        _processingCheckpoint = endPosition + 1;
        if (_processingCheckpoint > totalTickets) {
            _resetGame();
        }
    }

    function _resetGame() internal {
        delete _currentGameClaimers;
        if (s_pendingRollover > 0) {
            _prizePool = s_pendingRollover;
            s_pendingRollover = 0;
        }
        if (winningTicketId != 0) {
            uint256 tokenId = _positionToTokenId[winningTicketId];
            if (tokenId != 0) {
                delete _tokenIdToPosition[tokenId];
            }
            delete _positionToTokenId[winningTicketId];
            delete _tickets[winningTicketId];
        }
        _initBitfields(totalTickets);
        currentGameMinted = 0;
        _gameState = 0;
        currentRound = 0;
        currentGameId++;
        _processingCheckpoint = 0;
        emit GameFinalized(winningTicketId);
        winningTicketId = 0;
        emit GameStarted(currentGameId, totalTickets);
    }

    // -------------- Automation --------------
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory) {
        upkeepNeeded = (roundActive() && block.timestamp >= roundEndTime) || 
                   gameCompleted() || 
                   ((_gameState & GAME_STATE_ELIMINATING) != 0);
        return (upkeepNeeded, bytes(""));
    }

    function performUpkeep(bytes calldata) external override whenNotPaused {
        if (gameCompleted()) {
            finalizeGame();
        } else if (roundActive() && block.timestamp >= roundEndTime) {
            endRound();
        } else if ((_gameState & GAME_STATE_ELIMINATING) != 0) {
            processElimination();
        }
    }

    // -------------- Admin Functions --------------
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    


    function rerequestRandomness() external onlyOwner whenNotPaused {
        if (roundActive() || gameCompleted()) revert RerequestNotAllowedError();
        if (lastRequestId == 0) revert NoPendingRequestError();
        if (block.timestamp < vrfRequestTimestamp + vrfTimeout) revert RequestNotStaleError();
        if (vrfAdapter == address(0)) revert PendingAdapterNotSetError();
        lastRequestId = IGbitVRFAdapter(vrfAdapter).requestRandomness();
        _requestRound[lastRequestId] = currentRound;
        vrfRequestTimestamp = block.timestamp;
    }

    function restartGame() external onlyOwner whenNotPaused {
        if (!gameCompleted()) revert GameNotCompletedError();
        _resetGame();
    }

    function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant whenPaused {
        if (amount == 0) revert InvalidQuantityError();
        
        uint256 availableForWithdrawal = _prizePool + s_pendingRollover;
        if (amount > availableForWithdrawal) revert InvalidQuantityError();
        if (amount > address(this).balance) revert InvalidQuantityError();
        
        // Calculate how much to take from each source
        uint256 fromPrizePool = amount;
        uint256 fromRollover = 0;
        
        if (fromPrizePool > _prizePool) {
            fromRollover = fromPrizePool - _prizePool;
            fromPrizePool = _prizePool;
        }
        
        // Update state
        _prizePool -= fromPrizePool;
        s_pendingRollover -= fromRollover;
        
        // Transfer
        (bool success, ) = owner().call{value: amount}("");
        if (!success) {
            // Revert state changes on failure
            _prizePool += fromPrizePool;
            s_pendingRollover += fromRollover;
            revert WithdrawalFailedError();
        }
        
        emit EmergencyWithdrawal(owner(), amount, _prizePool, s_pendingRollover);
    }

    // -------------- Pull Payment Functions --------------
    function withdrawPendingFunds() external nonReentrant {
        uint256 amount = _pendingWithdrawals[msg.sender];
        if (amount == 0) revert NoFundsToWithdrawError();
        _processPendingWithdrawal(msg.sender);
    }

    function _processPendingWithdrawal(address payee) internal {
        uint256 amount = _pendingWithdrawals[payee];
        if (amount == 0) return;
        _pendingWithdrawals[payee] = 0;
        (bool success, ) = payable(payee).call{value: amount}("");
        if (!success) {
            _pendingWithdrawals[payee] = amount;
            revert WithdrawalFailedError();
        }
        emit WithdrawalComplete(payee, amount);
    }

    function _recordPendingWithdrawal(address recipient, uint256 amount, string memory /* reason */) internal {
        if (amount > 0 && recipient != address(0)) { _pendingWithdrawals[recipient] += amount; }
    }

    function pendingWithdrawalAmount(address account) external view returns (uint256) { return _pendingWithdrawals[account]; }

    function hasPendingWinnerPrize(address account) external view returns (bool, uint256) {
        uint256 amount = _pendingWithdrawals[account];
        if (amount == 0) { return (false, 0); }
        uint256 tokenCount = balanceOf(account);
        if (tokenCount == 0) { return (false, amount); }
        uint256 end = _nextTokenId;
        for (uint256 i = 1; i < end; i++) {
            if (_exists(i) && ownerOf(i) == account && _isWinnerToken[i]) {
                return (true, amount);
            }
        }
        return (false, amount);
    }

    // -------------- TokenURI --------------
    function tokenURI(uint256 tokenId) public view override(ERC721Upgradeable) returns (string memory) {
        if (!_exists(tokenId)) revert TokenDoesNotExistError();

        string memory baseURI = _baseURI();
        // The baseURI is expected to end with a "/"
        return string(abi.encodePacked(baseURI, tokenId.toString(), ".json"));
    }

    function _baseURI() internal view override(ERC721Upgradeable) returns (string memory) {
        return _baseTokenURI;
    }

    // -------------- Info Views --------------

    // getTicketsOwnedBy function removed as it's unused, gas-inefficient,
    // and could return misleading data without careful client-side filtering.
    // The frontend uses getBatchTicketInfo and filters by gameId.

    // -------------- VRF Adapter Management --------------
    function setVRFAdapterPending(address pending) external onlyOwner { pendingVrfAdapter = pending; }
    function acceptVRFAdapter() external onlyOwner { if (pendingVrfAdapter == address(0)) revert PendingAdapterNotSetError(); vrfAdapter = pendingVrfAdapter; pendingVrfAdapter = address(0); }

    // -------------- Accessors --------------
    function roundActive() public view returns (bool) { return (_gameState & GAME_STATE_ROUND_ACTIVE) != 0; }
    function gameCompleted() public view returns (bool) { return (_gameState & GAME_STATE_COMPLETED) != 0; }
    // commenting out to save bytecode size. must uncomment for stress test loop tests
    function eliminationBatchSize() public view returns (uint256) { return _eliminationBatchSize; }
    function isEliminating() public view returns (bool) { return (_gameState & GAME_STATE_ELIMINATING) != 0; }

    function getBatchTicketInfo(uint256[] calldata positions) external view returns (
        address[] memory owners,
        bool[] memory _isActive,
        bool[] memory _isListed,
        bool[] memory _hasOffer,
        address[] memory offerMakers,
        uint256[] memory listingPrices,
        uint256[] memory offerAmounts,
        uint32[] memory gameIds,
        uint32[] memory creationTimes
    ) {
        uint256 len = positions.length;
        owners = new address[](len);
        _isActive = new bool[](len);
        _isListed = new bool[](len);
        _hasOffer = new bool[](len);
        offerMakers = new address[](len);
        listingPrices = new uint256[](len);
        offerAmounts = new uint256[](len);
        gameIds = new uint32[](len);
        creationTimes = new uint32[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 position = positions[i];
            uint256 tokenId = _positionToTokenId[position];
            owners[i] = _ownerOrZero(tokenId);

            _isActive[i] = isActive(position);
            _isListed[i] = isListed(position);
            _hasOffer[i] = hasOffer(position);

            TicketData storage t = _tickets[position];
            offerMakers[i] = t.offerMaker;
            listingPrices[i] = t.listingPrice;
            offerAmounts[i] = t.offerAmount;
            gameIds[i] = t.gameId;
            creationTimes[i] = t.creationTime;
        }

        return (owners, _isActive, _isListed, _hasOffer, offerMakers, listingPrices, offerAmounts, gameIds, creationTimes);
    }

    function _ownerOrZero(uint256 tokenId) internal view returns (address) {
        if (tokenId != 0 && _exists(tokenId)) {
            return ownerOf(tokenId);
        }
        return address(0);
    }

    // -------------- Admin Setters --------------
    function setRoundDuration(uint256 newDuration) external onlyOwner { 
        if (roundActive()) revert RoundActiveError(); 
        if ((_gameState & GAME_STATE_ELIMINATING) != 0) revert EliminationInProgressError();
        roundDuration = newDuration; 
    }
    function setMaxClaimsPerAccount(uint256 newMax) external onlyOwner { 
        // if (roundActive()) revert RoundActiveError(); // COMMENTED OUT FOR SIZE OPTIMIZATION
        maxClaimsPerAccount = newMax; 
    }

    function setSecondaryMarketFeePercent(uint256 newFeePercent) external onlyOwner {
        // if (newFeePercent > 25) revert FeeTooHighError(); // COMMENTED OUT FOR SIZE OPTIMIZATION
        secondaryMarketFeePercent = newFeePercent;
    }

    function setPrizePoolPercent(uint256 newPrizePercent) external onlyOwner {
        // if (newPrizePercent > 25) revert PrizeTooHighError(); // COMMENTED OUT FOR SIZE OPTIMIZATION
        prizePoolPercent = newPrizePercent;
    }

    function setRolloverFeePercent(uint256 newRolloverPercent) external onlyOwner {
        // if (newRolloverPercent > 50) revert RolloverTooHighError(); // COMMENTED OUT FOR SIZE OPTIMIZATION
        rolloverFeePercent = newRolloverPercent;
    }

    function setVrfTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout < 1 hours) revert TimeoutTooShortError();
        vrfTimeout = newTimeout;
    }

    function setDealerAddress(address payable newDealerAddress) external onlyOwner {
        if (newDealerAddress == address(0)) revert InvalidDealerAddressError();
        dealerAddress = newDealerAddress;
    }
    
    function setEliminationBatchSize(uint256 newBatchSize) external onlyOwner {
        // Ensure batch size is reasonable (not too small or too large)
        // if (newBatchSize < 5) newBatchSize = 5; // COMMENTED OUT FOR SIZE OPTIMIZATION
        // if (newBatchSize > 50) newBatchSize = 50; // COMMENTED OUT FOR SIZE OPTIMIZATION
        _eliminationBatchSize = newBatchSize;
    }

    // ADDED TO MANAGE OFF-CHAIN METADATA URI
    function setBaseURI(string calldata baseURI) external onlyOwner {
        // Normalize the URI to ensure it ends with a trailing slash.
        bytes memory baseURIBytes = bytes(baseURI);
        if (baseURIBytes.length > 0 && baseURIBytes[baseURIBytes.length - 1] != '/') {
            _baseTokenURI = string(abi.encodePacked(baseURI, "/"));
        } else {
            _baseTokenURI = baseURI;
        }
        
        // As per EIP-4906, from tokenID 1 up to the total supply.
        // We use totalTickets as an approximation of final supply.
        emit BatchMetadataUpdate(1, totalTickets);
    }

    // -------------- Simple Views --------------
    function getClaimCount(address account) external view returns (uint256) {
        ClaimCounter storage counter = _claimCounters[account];
        if (counter.gameId == uint32(currentGameId)) { return counter.count; }
        return 0;
    }

    function getRemainingClaims(address account) external view returns (uint256) {
        uint256 used = this.getClaimCount(account);
        if (used >= maxClaimsPerAccount) return 0;
        return maxClaimsPerAccount - used;
    }

    function prizePool() external view returns (uint256) {
        return _prizePool;
    }


    // -------------- Fallback --------------
    receive() external payable {
        // Allow direct ETH transfers to seed the prize pool
        if (msg.value > 0) {
            _prizePool += msg.value;
            emit PrizePoolSeeded(msg.sender, msg.value);
        }
    }
    fallback() external { revert FunctionNotFoundError(); }

    // -------------- Storage gap --------------
    // Storage gap for future upgrades - V4 standalone deployment
    uint256[100] private __gap;
}


