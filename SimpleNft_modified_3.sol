// SPDX-License-Identifier: MIT
// Amended by HashLips
// Modified: Payment Splitting (2 recipients) + ERC-2981 Royalties (2.5%)

/**
  !Disclaimer!
  These contracts have been used to create tutorials,
  and was created for the purpose to teach people
  how to create smart contracts on the blockchain.
  Please review this code on your own before using any of
  the following code for production.
  The developer will not be responsible or liable for all loss or
  damage whatsoever caused by you participating in any way in the
  experimental code, whether putting money into the contract or
  using the code for your own project.
*/

pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract NFT is ERC721Enumerable, Ownable, IERC2981 {
    using Strings for uint256;

    // ─── Base NFT State ───────────────────────────────────────────────────────
    string baseURI;
    string public baseExtension = ".json";
    uint256 public cost = 0.05 ether;
    uint256 public maxSupply = 10000;
    uint256 public maxMintAmount = 20;
    bool public paused = false;
    bool public revealed = false;
    string public notRevealedUri;

    // ─── Payment Splitting ────────────────────────────────────────────────────
    address public recipient1;
    address public recipient2;
    uint256 public recipient1Share; // in basis points (e.g. 7000 = 70%)
    uint256 public recipient2Share; // in basis points (e.g. 3000 = 30%)
    uint256 private constant SPLIT_DENOMINATOR = 10000;

    // ─── ERC-2981 Royalties ───────────────────────────────────────────────────
    // 2.5% royalty → 250 basis points out of 10000
    uint256 private constant ROYALTY_BASIS_POINTS = 250;

    // ─── Events ───────────────────────────────────────────────────────────────
    event PaymentSplit(address indexed to, uint256 amount);
    event RecipientsUpdated(address recipient1, address recipient2);
    event SharesUpdated(uint256 share1, uint256 share2);

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _initBaseURI,
        string memory _initNotRevealedUri,
        address _recipient1,
        address _recipient2,
        uint256 _recipient1Share // e.g. 7000 for 70%; recipient2 gets the rest
    ) ERC721(_name, _symbol) {
        require(_recipient1 != address(0), "Recipient1 is zero address");
        require(_recipient2 != address(0), "Recipient2 is zero address");
        require(_recipient1Share <= SPLIT_DENOMINATOR, "Share exceeds 100%");

        setBaseURI(_initBaseURI);
        setNotRevealedURI(_initNotRevealedUri);

        recipient1 = _recipient1;
        recipient2 = _recipient2;
        recipient1Share = _recipient1Share;
        recipient2Share = SPLIT_DENOMINATOR - _recipient1Share;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────
    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    // ─── Mint ─────────────────────────────────────────────────────────────────
    function mint(uint256 _mintAmount) public payable {
        uint256 supply = totalSupply();
        require(!paused, "Contract is paused");
        require(_mintAmount > 0, "Mint amount must be > 0");
        require(_mintAmount <= maxMintAmount, "Exceeds max mint per tx");
        require(supply + _mintAmount <= maxSupply, "Exceeds max supply");

        if (msg.sender != owner()) {
            require(msg.value >= cost * _mintAmount, "Insufficient ETH sent");
        }

        for (uint256 i = 1; i <= _mintAmount; i++) {
            _safeMint(msg.sender, supply + i);
        }

        // Auto-split payment on every mint
        if (msg.value > 0) {
            _splitPayment(msg.value);
        }
    }

    // ─── Payment Split Logic ──────────────────────────────────────────────────

    /**
     * @dev Splits incoming ETH between the two recipients according to their shares.
     *      Called automatically on mint and can also be called manually via withdraw().
     */
    function _splitPayment(uint256 _amount) internal {
        uint256 amount1 = (_amount * recipient1Share) / SPLIT_DENOMINATOR;
        uint256 amount2 = _amount - amount1; // remainder goes to recipient2 (avoids rounding dust)

        (bool sent1, ) = payable(recipient1).call{value: amount1}("");
        require(sent1, "Payment to recipient1 failed");
        emit PaymentSplit(recipient1, amount1);

        (bool sent2, ) = payable(recipient2).call{value: amount2}("");
        require(sent2, "Payment to recipient2 failed");
        emit PaymentSplit(recipient2, amount2);
    }

    /**
     * @dev Withdraw any ETH remaining in the contract (e.g. owner-minted with value).
     *      Splits the full balance between the two recipients.
     */
    function withdraw() public payable onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        _splitPayment(balance);
    }

    // ─── Recipient / Share Management (Owner) ─────────────────────────────────

    function setRecipients(address _recipient1, address _recipient2) public onlyOwner {
        require(_recipient1 != address(0), "Recipient1 is zero address");
        require(_recipient2 != address(0), "Recipient2 is zero address");
        recipient1 = _recipient1;
        recipient2 = _recipient2;
        emit RecipientsUpdated(_recipient1, _recipient2);
    }

    /**
     * @dev Update split shares. _share1 is in basis points (e.g. 7000 = 70%).
     *      Recipient2 automatically gets the remainder.
     */
    function setShares(uint256 _share1) public onlyOwner {
        require(_share1 <= SPLIT_DENOMINATOR, "Share1 exceeds 100%");
        recipient1Share = _share1;
        recipient2Share = SPLIT_DENOMINATOR - _share1;
        emit SharesUpdated(_share1, recipient2Share);
    }

    // ─── ERC-2981 Royalties ───────────────────────────────────────────────────

    /**
     * @dev Returns royalty info per ERC-2981.
     *      2.5% of the sale price goes to the contract owner.
     * @param _tokenId  The NFT token ID (unused — same rate for all tokens).
     * @param _salePrice The sale price of the NFT.
     */
    function royaltyInfo(
        uint256 _tokenId,
        uint256 _salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        _tokenId; // silence unused variable warning
        receiver = owner();
        royaltyAmount = (_salePrice * ROYALTY_BASIS_POINTS) / SPLIT_DENOMINATOR;
    }

    // ─── ERC-165 supportsInterface ────────────────────────────────────────────

    /**
     * @dev Override required to support both ERC721Enumerable and ERC2981.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721Enumerable, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ─── View / Token URI ─────────────────────────────────────────────────────

    function walletOfOwner(address _owner) public view returns (uint256[] memory) {
        uint256 ownerTokenCount = balanceOf(_owner);
        uint256[] memory tokenIds = new uint256[](ownerTokenCount);
        for (uint256 i; i < ownerTokenCount; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(_owner, i);
        }
        return tokenIds;
    }

    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

        if (!revealed) {
            return notRevealedUri;
        }

        string memory currentBaseURI = _baseURI();
        return
            bytes(currentBaseURI).length > 0
                ? string(abi.encodePacked(currentBaseURI, tokenId.toString(), baseExtension))
                : "";
    }

    // ─── Owner Settings ───────────────────────────────────────────────────────

    function reveal() public onlyOwner {
        revealed = true;
    }

    function setCost(uint256 _newCost) public onlyOwner {
        cost = _newCost;
    }

    function setMaxMintAmount(uint256 _newMaxMintAmount) public onlyOwner {
        maxMintAmount = _newMaxMintAmount;
    }

    function setNotRevealedURI(string memory _notRevealedURI) public onlyOwner {
        notRevealedUri = _notRevealedURI;
    }

    function setBaseURI(string memory _newBaseURI) public onlyOwner {
        baseURI = _newBaseURI;
    }

    function setBaseExtension(string memory _newBaseExtension) public onlyOwner {
        baseExtension = _newBaseExtension;
    }

    function pause(bool _state) public onlyOwner {
        paused = _state;
    }

    // ─── Receive ETH ─────────────────────────────────────────────────────────
    receive() external payable {}
}

