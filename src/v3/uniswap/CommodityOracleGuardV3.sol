// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICommodityIdentityV3 {
    function assetId() external view returns (bytes32);
}

interface ICommodityPriceFeedV3 {
    struct Config {
        bool enabled;
        bool paused;
        uint32 maxAge;
        uint256 minPriceWad;
        uint256 maxPriceWad;
    }

    struct Observation {
        uint256 priceWad;
        uint64 observedAt;
        uint64 updatedAt;
    }
    function paused() external view returns (bool);
    function assetConfig(bytes32 id) external view returns (Config memory);
    function latest(bytes32 id) external view returns (Observation memory);
    function price(bytes32 id) external view returns (uint256 priceWad, uint64 observedAt);
}

/// Execution-time source health checks. A healthy reference is NOT a swap quote or a minOut policy.
contract CommodityOracleGuardV3 {
    error BAD_CONFIG();
    error WRONG_CHAIN();
    error UNKNOWN_ASSET();
    error IDENTITY_CHANGED();
    error SOURCE_UNAVAILABLE();
    error INVALID_OBSERVATION();
    error STALE_OBSERVATION();
    error SOURCE_POLICY_CHANGED();
    uint256 public immutable chainId;
    ICommodityPriceFeedV3 public immutable feed;
    uint32 public immutable maxAgeCeiling;
    // Independently cap actual observation age. A source may publish a longer SLA,
    // but cannot make an old observation executable by extending that SLA.
    uint32 public immutable maxObservationAge;
    mapping(address => bytes32) public assetIds;

    constructor(
        uint256 chainId_,
        ICommodityPriceFeedV3 feed_,
        uint32 maxAgeCeiling_,
        uint32 maxObservationAge_,
        address[] memory assets,
        bytes32[] memory ids
    ) {
        if (block.chainid != chainId_) revert WRONG_CHAIN();
        if (
            address(feed_).code.length == 0 || maxAgeCeiling_ == 0 || maxObservationAge_ == 0
                || maxObservationAge_ > maxAgeCeiling_ || assets.length == 0 || assets.length > 64
                || assets.length != ids.length
        ) revert BAD_CONFIG();
        chainId = chainId_;
        feed = feed_;
        maxAgeCeiling = maxAgeCeiling_;
        maxObservationAge = maxObservationAge_;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i].code.length == 0 || ids[i] == bytes32(0) || assetIds[assets[i]] != bytes32(0)) {
                revert BAD_CONFIG();
            }
            if (ICommodityIdentityV3(assets[i]).assetId() != ids[i]) revert BAD_CONFIG();
            assetIds[assets[i]] = ids[i];
        }
    }

    function hasAsset(address asset) external view returns (bool) {
        return assetIds[asset] != bytes32(0);
    }

    function validate(address asset) public view {
        if (block.chainid != chainId) revert WRONG_CHAIN();
        bytes32 id = assetIds[asset];
        if (id == bytes32(0)) revert UNKNOWN_ASSET();
        if (ICommodityIdentityV3(asset).assetId() != id) revert IDENTITY_CHANGED();
        if (feed.paused()) revert SOURCE_UNAVAILABLE();
        ICommodityPriceFeedV3.Config memory c = feed.assetConfig(id);
        if (!c.enabled || c.paused) revert SOURCE_UNAVAILABLE();
        if (c.maxAge > maxAgeCeiling) revert SOURCE_POLICY_CHANGED();
        ICommodityPriceFeedV3.Observation memory o = feed.latest(id);
        if (
            c.maxAge == 0 || c.minPriceWad > c.maxPriceWad || o.priceWad == 0 || o.priceWad < c.minPriceWad
                || o.priceWad > c.maxPriceWad || o.observedAt == 0 || o.updatedAt < o.observedAt
                || o.updatedAt > block.timestamp
        ) revert INVALID_OBSERVATION();
        uint32 effectiveMaxAge = c.maxAge < maxObservationAge ? c.maxAge : maxObservationAge;
        if (block.timestamp >= uint256(o.observedAt) + effectiveMaxAge) revert STALE_OBSERVATION();
        (uint256 price_, uint64 observed_) = feed.price(id);
        if (price_ != o.priceWad || observed_ != o.observedAt) revert INVALID_OBSERVATION();
    }
}
