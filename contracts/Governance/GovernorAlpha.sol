pragma solidity ^0.8.0;
import "../../interfaces/GovernorBravoInterfaces.sol";
contract GovernorAlpha{
    /// @notice The name of this contract
    string public constant name = "Compound Governor Alpha";

    // @notice The number of votes in support of a proposal required in order for a quorum to be reached and for a vote to succeed
    function quorumVotes() public pure returns (uint) { return 400000e18; } // 400,000 = 4% of Comp
    
    /// @notice The number of votes required in order for a voter to become a proposer
    function proposalThreshold() public pure returns (uint) { return 100000e18; } // 100,000 = 1% of Comp

    /// @notice The maximum number of actions that can be included in a proposal
    function proposalMaxOperations() public pure returns (uint) { return 10; } // 10 actions

    /// @notice The delay before voting on a proposal may take place, once proposed
    function votingDelay() public pure returns (uint) { return 1; } // 1 block

    /// @notice The duration of voting on a proposal, in blocks
    function votingPeriod() public pure returns (uint) { return 17280; } // ~3 days in blocks (assuming 15s blocks)

    // @notice The address of the Compound Protocol Timelock
    TimelockInterface public timelock;

    // @notice The address of the Compound governance token
    CompInterface public comp;

    /// @notice The address of the Governor Guardian
    address public guardian;

    /// @notice The total number of proposals
    uint public proposalCount;


    /**
        @param id: Unique id for looking up a proposal
        @param proposer: Creator of the proposal
        @param eta: The timestamp that the proposal will be available for execution, set once the vote succeeds
        @param targets: the ordered list of target addresses for calls to be made
        @param values: The ordered list of values (i.e. msg.value) to be passed to the calls to be made
        @param signatures: The ordered list of function signatures to be called
        @param calldatas: The ordered list of calldata to be passed to each call
        @param startBlock: The block at which voting begins: holders must delegate their votes prior to this block
        @param endBlock: The block at which voting ends: votes must be cast prior to this block
        @param forVotes: Current number of votes in favor of this proposal
        @param againstVotes: Current number of votes in opposition to this proposal
        @param canceled: Flag marking whether the proposal has been canceled
        @param executed: Flag marking whether the proposal has been executed
        @param receipts: Receipts of ballots for the entire set of voters
       
     */
    struct Proposal{
        uint id;
        address proposer;
        uint eta;
        address[] targets;
        uint[] values;
        string[] signatures;
        bytes[] calldatas;
        uint startBlock;
        uint endBlock;
        uint forVotes;
        uint againstVotes;
        bool canceled;
        bool executed;
        mapping (address => Receipt) receipts;
    }

    /**
        @param hasVoted: Whether or not the voter supports the proposal
        @param support: Whether or not the voter supports the proposal
        @param votes: The number of votes the voter had, which were cast

     */
    struct Receipt {
        bool hasVoted;
        bool support;
        uint96 votes;
    }

    /// @notice Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    /// @notice The official record of all proposals ever proposed
    mapping (uint => Proposal) public proposals;

    /// @notice The latest proposal for each proposers
    mapping (address => uint) public latestProposalIds;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name, uint256 chainId, address verifyingContract)");

    /// @notice The EIP-712 typehash for the ballot struct used by the contract
    bytes32 public constant BALLOT_TYPEHASH = keccak256("Ballot(uint256 proposalId, bool support)");

    /// @notice An event emitted when a proposal is created
    event ProposalCreated(uint id, address proposer, address[] targets, uint[] values, string[] signatures, bytes[] calldatas, uint startBlock, uint endBlock, string description);

    /// @notice An event emitted when a vote has been cast on a proposal
    event VoteCast(address voter, uint proposalId, bool support, uint votes);

    // @notice An event emitted when a proposal has been canceled
    event ProposalCanceled(uint id);

    /// @notice An event emitted when a proposal has been queued in the Timelock
    event ProposalQueued(uint id, uint eta);

    /// @notice An event emitted when a proposal has been executed in the Timelock
    event ProposalExecuted(uint id);

    constructor(address timelock_, address comp_, address guardian_) {
        timelock = TimelockInterface(timelock_);
        comp = CompInterface(comp_);
        guardian = guardian_;
    }

    function propose(address[] memory targets, uint[] memory values, string[] memory signatures, bytes[] memory calldatas, string memory description) public returns (uint) {
        require(comp.getPriorVotes(msg.sender, sub256(block.number,1))>proposalThreshold(), "proposer votes below proposal threshold");
        require(targets.length == values.length && targets.length == signatures.length && targets.length == calldatas.length, "proposal function information parity mismatch");
        require(targets.length != 0, "GovernorAlpha::propose: must provide actions");
        require(targets.length <= proposalMaxOperations(), "GovernorAlpha::propose: too many actions");

        uint latestProposalId = latestProposalIds[msg.sender];

        if (latestProposalId != 0){
            ProposalState proposersLatestProposalState = state(latestProposalId);
            require(proposersLatestProposalState != ProposalState.Active, "GovernorAlpha::propose: one live proposal per proposer, found an already active proposal");
            require(proposersLatestProposalState != ProposalState.Pending, "GovernorAlpha::propose: one live proposal per proposer, found an already pending proposal");
        }

        uint startBlock = add256(block.number, votingDelay());
        uint endBlock = add256(startBlock, votingPeriod());

        proposalCount++;
        Proposal storage newProposal = proposals[proposalCount];
        newProposal.id = proposalCount;
        newProposal.proposer = msg.sender;
        newProposal.eta = 0;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.signatures = signatures;
        newProposal.calldatas = calldatas;
        newProposal.startBlock = startBlock;
        newProposal.endBlock = endBlock;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.canceled = false;
        newProposal.executed = false;
       
        latestProposalIds[newProposal.proposer] = newProposal.id;

        emit ProposalCreated(newProposal.id, msg.sender, targets, values, signatures, calldatas, startBlock, endBlock, description);
        return newProposal.id;
    }

    function queue(uint proposalId) public {
        require(state(proposalId) == ProposalState.Succeeded);
        Proposal storage proposal = proposals[proposalId];

        uint eta = add256(block.timestamp, timelock.delay());

        for(uint i = 0; i < proposal.targets.length; i++){
            _queueOrRevert(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], eta);
        }
        proposal.eta = eta;
        emit ProposalQueued(proposalId, eta);
    }

    function _queueOrRevert(address target, uint value, string memory signature, bytes memory data, uint eta) internal {
        require(!timelock.queuedTransactions(keccak256(abi.encode(target, value, signature, data, eta))), "GovernorAlpha::_queueOrRevert: proposal action already queued at eta");
        timelock.queueTransaction(target, value, signature, data, eta);
    }

    function execute(uint proposalId) public payable{
        require(state(proposalId) == ProposalState.Queued, "GovernorAlpha::execute: proposal can only be executed if it is queued");
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;

        for(uint i = 0; i < proposal.targets.length; i++){
            timelock.executeTransaction{value: proposal.values[i]}(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], proposal.eta);

        }
        emit ProposalExecuted(proposalId);
    }
    function state(uint proposalId) public view returns (ProposalState){
        require(proposalCount >= proposalId && proposalId > 0, "GovernorAlpha: state: invalid propsalId");
        Proposal storage proposal = proposals[proposalId];

        if (proposal.canceled){
            return ProposalState.Canceled;
        }else if(block.number <= proposal.startBlock){
            return ProposalState.Pending;
        }else if(block.number <= proposal.endBlock){
            return ProposalState.Active;
        }else if(proposal.forVotes <= proposal.againstVotes || proposal.forVotes < quorumVotes()){
            return ProposalState.Defeated;
        }else if (proposal.eta == 0){
            return ProposalState.Succeeded;
        }else if (proposal.executed){
            return ProposalState.Executed;
        }else if(block.timestamp >= add256(proposal.eta, timelock.GRACE_PERIOD())){
            return ProposalState.Expired;
        }else{
            return ProposalState.Queued;
        }
    }

     function sub256(uint256 a, uint256 b) internal pure returns (uint) {
        require(b <= a, "subtraction underflow");
        return a - b;
    }
    function add256(uint256 a, uint256 b) internal pure returns (uint) {
        uint c = a + b;
        require(c >= a, "addition overflow");
        return c;
    }
}