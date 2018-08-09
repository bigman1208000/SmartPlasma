pragma solidity ^0.4.23;

import "./libraries/datastructures/PlasmaLib.sol";
import "./libraries/datastructures/Transaction.sol";
import "./libraries/merkle.sol";
import "./libraries/openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "./libraries/openzeppelin-solidity/contracts/math/SafeMath.sol";

contract RootChain is Ownable {
    using Merkle for bytes32;
    using Transaction for bytes;
    using SafeMath for uint256;

    event Deposit(address depositor, uint256 amount, uint256 uid);

    uint256 public depositCount;
    uint256 public blockNumber;
    uint256 challengePeriod;
    address operator;

    mapping(uint256 => bytes32) public childChain;
    mapping(uint256 => exit) public exits;
    mapping(bytes32 => uint256) public wallet;
    mapping(uint256 => dispute) disputes;
    // key = checkpoint hash - checkpoint merkle root,
    // value = unix timestamp - checkpoint create time.
    mapping(bytes32 => uint256) public checkpoints;
    // checkpoint disputes
    mapping(uint256 => mapping(bytes32 => dispute)) checkpointDisputes;

    struct exit {
        // 0 - did not request to exit,
        // 1 - in challenge proceeding, it blocks a exit, TODO: remove it
        // 2 - in anticipation of exit,
        // 3 - a exit was made.
        uint256 state;
        uint256 exitTime;
        uint256 exitTxBlkNum;
        bytes exitTx;
        uint256 txBeforeExitTxBlkNum;
        bytes txBeforeExitTx;
    }

    struct challenge {
        bool exists;
        bytes challengeTx;
        uint256 blockNumber;
    }

    struct dispute {
        uint256 len;
        mapping(uint256 => challenge) challenges;
        mapping(bytes => uint256) indexes;
    }

    constructor (address _operator) public {
        blockNumber = 0;
        challengePeriod = 2 weeks;
        depositCount = 0;
        operator = _operator;
    }

    modifier onlyOperator() {
        require(msg.sender == operator);
        _;
    }

    function deposit(
        address account,
        address currency,
        uint256 amount
    )
        public
        onlyOwner
        returns (bytes32)
    {
        bytes32 uid = PlasmaLib.generateUID(
            account,
            currency,
            depositCount
        );
        wallet[uid] = amount;
        depositCount = depositCount.add(uint256(1));

        emit Deposit(account, amount, uint256(uid));

        return uid;
    }

    function newBlock(bytes32 hash) public onlyOperator {
        blockNumber = blockNumber.add(uint256(1));
        childChain[blockNumber] = hash;
    }

    function newCheckpoint(bytes32 hash) public onlyOperator {
        require(checkpoints[hash] == 0);

        checkpoints[hash]= now;
    }

    function startExit(
        bytes previousTx,
        bytes previousTxProof,
        uint256 previousTxBlockNum,
        bytes lastTx,
        bytes lastTxProof,
        uint256 lastTxBlockNum
    )
        public
    {
        Transaction.Tx memory prevDecodedTx = previousTx.createTx();
        Transaction.Tx memory decodedTx = lastTx.createTx();

        require(previousTxBlockNum == decodedTx.prevBlock);
        require(prevDecodedTx.uid == decodedTx.uid);
        require(prevDecodedTx.amount == decodedTx.amount);
        require(prevDecodedTx.newOwner == decodedTx.signer);
        require(decodedTx.nonce == prevDecodedTx.nonce.add(uint256(1)));
        require(msg.sender == decodedTx.newOwner);
        require(wallet[bytes32(decodedTx.uid)] != 0);

        bytes32 prevTxHash = prevDecodedTx.hash;
        bytes32 prevBlockRoot = childChain[previousTxBlockNum];
        bytes32 txHash = decodedTx.hash;
        bytes32 blockRoot = childChain[lastTxBlockNum];

        require(
            prevTxHash.checkMembership(
                prevDecodedTx.uid,
                prevBlockRoot,
                previousTxProof
            )
        );
        require(
            txHash.checkMembership(
                decodedTx.uid,
                blockRoot,
                lastTxProof
            )
        );

        // Record the exit tx.
        require(exits[decodedTx.uid].state == 0);
        require(challengesLength(decodedTx.uid) == 0);

        exits[decodedTx.uid] = exit({
            state: 2,
            exitTime: now.add(challengePeriod),
            exitTxBlkNum: lastTxBlockNum,
            exitTx: lastTx,
            txBeforeExitTxBlkNum: previousTxBlockNum,
            txBeforeExitTx: previousTx
        });
    }

    function finishExit(
        address account,
        bytes previousTx,
        bytes previousTxProof,
        uint256 previousTxBlockNum,
        bytes lastTx,
        bytes lastTxProof,
        uint256 lastTxBlockNum
    )
        public
        onlyOwner
        returns (bytes32)
    {
        Transaction.Tx memory prevDecodedTx = previousTx.createTx();
        Transaction.Tx memory decodedTx = lastTx.createTx();

        require(previousTxBlockNum == decodedTx.prevBlock);
        require(prevDecodedTx.uid == decodedTx.uid);
        require(prevDecodedTx.amount == decodedTx.amount);
        require(prevDecodedTx.newOwner == decodedTx.signer);
        require(account == decodedTx.newOwner);

        bytes32 prevTxHash = prevDecodedTx.hash;
        bytes32 prevBlockRoot = childChain[previousTxBlockNum];
        bytes32 txHash = decodedTx.hash;
        bytes32 blockRoot = childChain[lastTxBlockNum];

        require(
            prevTxHash.checkMembership(
                prevDecodedTx.uid,
                prevBlockRoot,
                previousTxProof
            )
        );

        require(
            txHash.checkMembership(
                decodedTx.uid,
                blockRoot,
                lastTxProof
            )
        );

        require(exits[decodedTx.uid].exitTime < now);
        require(exits[decodedTx.uid].state == 2);
        require(challengesLength(decodedTx.uid) == 0);

        exits[decodedTx.uid].state = 3;

        delete(wallet[bytes32(decodedTx.uid)]);

        return bytes32(decodedTx.uid);
    }

    function challengeExit(
        uint256 uid,
        bytes challengeTx,
        bytes proof,
        uint challengeBlockNum
    )
        public
    {
        require(exits[uid].state == 2);

        Transaction.Tx memory exitDecodedTx = (exits[uid].exitTx).createTx();
        Transaction.Tx memory beforeExitDecodedTx = (exits[uid].txBeforeExitTx).createTx();
        Transaction.Tx memory challengeDecodedTx = challengeTx.createTx();

        require(exitDecodedTx.uid == challengeDecodedTx.uid);
        require(exitDecodedTx.amount == challengeDecodedTx.amount);

        bytes32 txHash = challengeDecodedTx.hash;
        bytes32 blockRoot = childChain[challengeBlockNum];

        require(txHash.checkMembership(uid, blockRoot, proof));

        // test challenge #1 & test challenge #2
        if (exitDecodedTx.newOwner == challengeDecodedTx.signer &&
        exitDecodedTx.nonce < challengeDecodedTx.nonce) {
            delete exits[uid];
            return;
        }

        // test challenge #3
        if (challengeBlockNum < exits[uid].exitTxBlkNum  &&
        beforeExitDecodedTx.newOwner == challengeDecodedTx.signer &&
        challengeDecodedTx.nonce > beforeExitDecodedTx.nonce) {
            delete exits[uid];
            return;
        }

        // test challenge #4
        if (challengeBlockNum < exits[uid].txBeforeExitTxBlkNum ) {
            exits[uid].state = 1;
            addChallenge(uid, challengeTx, challengeBlockNum);
        }

        require(exits[uid].state == 1);
    }

    function challengeCheckpoint(
        uint256 uid,
        bytes32 checkpointRoot,
        bytes checkpointProof,
        uint256 wrongNonce,
        bytes lastTx,
        bytes lastTxProof,
        uint lastTxBlockNum
    )
        public
    {
        require(checkpoints[checkpointRoot] != 0 &&
        checkpoints[checkpointRoot].add(challengePeriod) < now); // TODO: more strong time check
        require(!checkpointIsChallenge(uid, checkpointRoot, lastTx));

        Transaction.Tx memory lastTxDecoded = lastTx.createTx();

        require(msg.sender == lastTxDecoded.newOwner);

        bytes32 txHash = lastTxDecoded.hash;
        bytes32 blockRoot = childChain[lastTxBlockNum];
        bytes32 lastNonceHash = bytes32(lastTxDecoded.nonce);
        bytes32 wrongNonceHash = bytes32(wrongNonce);

        require(
            txHash.checkMembership(
                uid,
                blockRoot,
                lastTxProof
            )
        );
        require(
            wrongNonceHash.checkMembership(
                uid,
                checkpointRoot,
                checkpointProof
            )
        );

        if (wrongNonce > lastTxDecoded.nonce) {
            addCheckpointChallenge(
                uid,
                checkpointRoot,
                lastTx,
                lastTxBlockNum
            );
        }
    }

    // test respond to a challenge #1
    function respondChallengeExit(
        uint256 uid,
        bytes challengeTx,
        bytes respondTx,
        bytes proof,
        uint blockNum
    )
        public
    {
        require(challengeExists(uid, challengeTx));
        require(exits[uid].state == 1);

        Transaction.Tx memory challengeDecodedTx = challengeTx.createTx();
        Transaction.Tx memory respondDecodedTx = respondTx.createTx();

        require(challengeDecodedTx.uid == respondDecodedTx.uid);
        require(challengeDecodedTx.amount == respondDecodedTx.amount);
        require(challengeDecodedTx.newOwner == respondDecodedTx.signer);
        require(challengeDecodedTx.nonce.add(uint256(1)) == respondDecodedTx.nonce);
        require(blockNum < exits[uid].txBeforeExitTxBlkNum);

        bytes32 txHash = respondDecodedTx.hash;
        bytes32 blockRoot = childChain[blockNum];

        require(txHash.checkMembership(uid, blockRoot, proof));

        removeChallenge(uid, challengeTx);

        if (challengesLength(uid) == 0) {
            exits[uid].state = 2;
        }
    }

    function respondCheckpointChallengeExit(
        uint256 uid,
        bytes32 checkpointRoot,
        bytes challengeTx,
        bytes respondTx,
        bytes proof,
        uint blockNum
    )
        public
    {
        require(checkpointIsChallenge(uid, checkpointRoot, challengeTx));

        Transaction.Tx memory challengeDecodedTx = challengeTx.createTx();
        Transaction.Tx memory respondDecodedTx = respondTx.createTx();

        require(challengeDecodedTx.uid == respondDecodedTx.uid);
        require(challengeDecodedTx.amount == respondDecodedTx.amount);
        require(challengeDecodedTx.newOwner == respondDecodedTx.signer);
        require(challengeDecodedTx.nonce.add(uint256(1)) == respondDecodedTx.nonce);

        bytes32 txHash = respondDecodedTx.hash;
        bytes32 blockRoot = childChain[blockNum];

        require(txHash.checkMembership(uid, blockRoot, proof));

        removeCheckpointChallenge(uid, checkpointRoot, challengeTx);
    }

    function challengeExists(
        uint256 uid,
        bytes challengeTx
    )
        public
        view
        returns(bool)
    {
        uint256 index = disputes[uid].indexes[challengeTx];
        if (index == 0) {
            return false;
        }
        return disputes[uid].challenges[index].exists;
    }

    function checkpointIsChallenge(
        uint256 uid,
        bytes32 checkpoint,
        bytes challengeTx
    )
        public
        view
        returns(bool)
    {
        uint256 index = checkpointDisputes[uid][checkpoint].indexes[challengeTx];
        if (index == 0) {
            return false;
        }
        return checkpointDisputes[uid][checkpoint].challenges[index].exists;
    }

    function challengesLength(
        uint256 uid
    )
        public
        view
        returns(uint256)
    {
        uint256 origLen = disputes[uid].len;

        if (origLen == 0) {
            return uint256(0);
        }
        return(origLen.sub(uint256(1)));
    }

    function checkpointChallengesLength(
        uint256 uid,
        bytes32 checkpoint
    )
        public
        view
        returns(uint256)
    {
        uint256 origLen = checkpointDisputes[uid][checkpoint].len;

        if (origLen == 0) {
            return uint256(0);
        }
        return(origLen.sub(uint256(1)));
    }

    function getChallenge(
        uint256 uid,
        uint256 index
    )
        public
        view
        returns(bytes challengeTx, uint256 challengeBlock)
    {
        challenge storage che = disputes[uid].challenges[index.add(uint256(1))];

        return(che.challengeTx, che.blockNumber);
    }

    function getCheckpointChallenge(
        uint256 uid,
        bytes32 checkpoint,
        uint256 index
    )
        public
        view
        returns(bytes challengeTx, uint256 challengeBlock)
    {
        challenge storage che = checkpointDisputes[uid][checkpoint].challenges[index.add(uint256(1))];

        return(che.challengeTx, che.blockNumber);
    }

    function addCheckpointChallenge(
        uint256 uid,
        bytes32 checkpoint,
        bytes challengeTx,
        uint challengeBlockNumber
    )
        private
    {
        uint256 indexTx = checkpointDisputes[uid][checkpoint].indexes[challengeTx];

        require(indexTx == 0);

        challenge memory cha = challenge({
            exists: true,
            challengeTx: challengeTx,
            blockNumber: challengeBlockNumber
            });

        // index 1 is magic number
        if (checkpointDisputes[uid][checkpoint].len == 0) {
            checkpointDisputes[uid][checkpoint].len = 1;
        }

        uint256 currentLen = checkpointDisputes[uid][checkpoint].len;

        checkpointDisputes[uid][checkpoint].challenges[currentLen] = cha;
        checkpointDisputes[uid][checkpoint].indexes[challengeTx] = currentLen;
        checkpointDisputes[uid][checkpoint].len = currentLen.add(uint256(1));
    }

    function addChallenge(
        uint256 uid,
        bytes challengeTx,
        uint challengeBlockNumber
    )
        private
    {
        uint256 indexTx = disputes[uid].indexes[challengeTx];

        require(indexTx == 0);

        challenge memory cha = challenge({
            exists: true,
            challengeTx: challengeTx,
            blockNumber: challengeBlockNumber
        });

        // index 1 is magic number
        if (disputes[uid].len == 0) {
            disputes[uid].len = 1;
        }

        disputes[uid].challenges[disputes[uid].len] = cha;
        disputes[uid].indexes[challengeTx] = disputes[uid].len;
        disputes[uid].len = disputes[uid].len.add(uint256(1));
    }

    function removeCheckpointChallenge(
        uint256 uid,
        bytes32 checkpoint,
        bytes challengeTx
    )
        private
    {
        uint256 indexTx = checkpointDisputes[uid][checkpoint].indexes[challengeTx];

        require(indexTx != 0);

        delete(checkpointDisputes[uid][checkpoint].challenges[indexTx]);
        delete(checkpointDisputes[uid][checkpoint].indexes[challengeTx]);

        uint256 lastIndex = checkpointDisputes[uid][checkpoint].len.sub(uint256(1));

        if (indexTx != lastIndex) {
            challenge storage lastChe = checkpointDisputes[uid][checkpoint].challenges[lastIndex];
            checkpointDisputes[uid][checkpoint].challenges[indexTx] = lastChe;
            checkpointDisputes[uid][checkpoint].indexes[lastChe.challengeTx] = indexTx;
            delete(checkpointDisputes[uid][checkpoint].challenges[lastIndex]);
        }

        // index 1 is magic number
        if (lastIndex == 1) {
            checkpointDisputes[uid][checkpoint].len = 0;
            return;
        }

        checkpointDisputes[uid][checkpoint].len = lastIndex;
    }

    function removeChallenge(
        uint256 uid,
        bytes challengeTx
    )
        private
    {
        uint256 indexTx = disputes[uid].indexes[challengeTx];

        require(indexTx != 0);

        delete(disputes[uid].challenges[indexTx]);
        delete(disputes[uid].indexes[challengeTx]);

        uint256 lastIndex = disputes[uid].len.sub(uint256(1));

        if (indexTx != lastIndex) {
            challenge storage lastChe = disputes[uid].challenges[lastIndex];
            disputes[uid].challenges[indexTx] = lastChe;
            disputes[uid].indexes[lastChe.challengeTx] = indexTx;
            delete(disputes[uid].challenges[lastIndex]);
        }

        // index 1 is magic number
        if (lastIndex == 1) {
            disputes[uid].len = 0;
            return;
        }

        disputes[uid].len = lastIndex;
    }
}