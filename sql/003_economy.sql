CREATE TABLE IF NOT EXISTS `qbhousing_agents` (
  `property_id` VARCHAR(64) NOT NULL, `citizenid` VARCHAR(50) NOT NULL,
  PRIMARY KEY (`property_id`,`citizenid`),
  FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_listings` (
  `id` VARCHAR(64) NOT NULL, `property_id` VARCHAR(64) NOT NULL,
  `channel` VARCHAR(16) NOT NULL, `seller` VARCHAR(50) NULL, `agent` VARCHAR(50) NULL,
  `buyer` VARCHAR(50) NULL, `biography` TEXT NOT NULL, `price` BIGINT UNSIGNED NOT NULL,
  `commission_policy` LONGTEXT NULL, `policy_version` INT UNSIGNED NOT NULL DEFAULT 1,
  `status` VARCHAR(16) NOT NULL, `ownership_revision` INT UNSIGNED NOT NULL,
  `created_at` BIGINT NOT NULL,
  `active_property` VARCHAR(64) GENERATED ALWAYS AS (CASE WHEN `status`='active' THEN `property_id` ELSE NULL END) STORED,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_housing_active_listing` (`active_property`),
  KEY `idx_housing_listing_property` (`property_id`,`created_at`),
  FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_offers` (
  `id` VARCHAR(64) NOT NULL, `listing_id` VARCHAR(64) NOT NULL,
  `buyer` VARCHAR(50) NOT NULL, `amount` BIGINT UNSIGNED NOT NULL,
  `status` VARCHAR(16) NOT NULL, `recommendation` TEXT NULL, `created_at` BIGINT NOT NULL,
  `accepted_listing` VARCHAR(64) GENERATED ALWAYS AS (CASE WHEN `status`='accepted' THEN `listing_id` ELSE NULL END) STORED,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_housing_accepted_offer` (`accepted_listing`),
  KEY `idx_housing_offer_buyer` (`buyer`,`status`),
  FOREIGN KEY (`listing_id`) REFERENCES `qbhousing_listings` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_sale_approvals` (
  `offer_id` VARCHAR(64) NOT NULL, `citizenid` VARCHAR(50) NOT NULL,
  `ownership_revision` INT UNSIGNED NOT NULL, `approved` TINYINT(1) NOT NULL,
  PRIMARY KEY (`offer_id`,`citizenid`),
  FOREIGN KEY (`offer_id`) REFERENCES `qbhousing_offers` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_offer_history` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, `offer_id` VARCHAR(64) NOT NULL,
  `actor` VARCHAR(50) NOT NULL, `action` VARCHAR(32) NOT NULL, `note` TEXT NULL,
  `created_at` BIGINT NOT NULL, PRIMARY KEY (`id`), KEY (`offer_id`,`created_at`),
  FOREIGN KEY (`offer_id`) REFERENCES `qbhousing_offers` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_transactions` (
  `id` VARCHAR(100) NOT NULL, `property_id` VARCHAR(64) NOT NULL,
  `kind` VARCHAR(24) NOT NULL, `actor` VARCHAR(50) NULL,
  `status` VARCHAR(16) NOT NULL, `request` LONGTEXT NOT NULL,
  `result` LONGTEXT NOT NULL, `error` VARCHAR(256) NULL,
  `created_at` BIGINT NOT NULL, `updated_at` BIGINT NOT NULL,
  `active_property` VARCHAR(64) GENERATED ALWAYS AS (CASE WHEN `status`='pending' THEN `property_id` ELSE NULL END) STORED,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_housing_pending_transaction` (`active_property`), KEY (`status`,`updated_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_ledger` (
  `operation_id` VARCHAR(100) NOT NULL, `leg` INT UNSIGNED NOT NULL,
  `citizenid` VARCHAR(50) NULL, `account` VARCHAR(50) NULL,
  `amount` BIGINT NOT NULL, `kind` VARCHAR(16) NOT NULL,
  PRIMARY KEY (`operation_id`,`leg`), FOREIGN KEY (`operation_id`) REFERENCES `qbhousing_transactions` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_leases` (
  `id` VARCHAR(64) NOT NULL, `property_id` VARCHAR(64) NOT NULL,
  `tenant` VARCHAR(50) NOT NULL, `landlord` VARCHAR(50) NOT NULL,
  `interval_name` VARCHAR(8) NOT NULL, `rent` BIGINT UNSIGNED NOT NULL,
  `deposit` BIGINT UNSIGNED NOT NULL DEFAULT 0, `deposit_remaining` BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `permissions` LONGTEXT NOT NULL, `status` VARCHAR(16) NOT NULL,
  `revision` INT UNSIGNED NOT NULL DEFAULT 1, `deposit_review_seconds` INT UNSIGNED NOT NULL DEFAULT 172800,
  `ownership_revision` INT UNSIGNED NOT NULL, `owner_payees` LONGTEXT NULL,
  `missed_limit` INT UNSIGNED NULL, `policy_version` INT UNSIGNED NOT NULL DEFAULT 1,
  `deposit_release_at` BIGINT NULL,
  `next_due` BIGINT NULL, `paid_through` BIGINT NULL, `missed` INT UNSIGNED NOT NULL DEFAULT 0,
  `end_at` BIGINT NULL, `created_at` BIGINT NOT NULL,
  `active_property` VARCHAR(64) GENERATED ALWAYS AS (CASE WHEN `status` IN ('proposed','active','evicting','ending') THEN `property_id` ELSE NULL END) STORED,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_housing_active_lease` (`active_property`), KEY (`tenant`,`status`), KEY (`status`,`next_due`),
  FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_rent_periods` (
  `lease_id` VARCHAR(64) NOT NULL, `period_start` BIGINT NOT NULL, `period_end` BIGINT NOT NULL,
  `amount` BIGINT UNSIGNED NOT NULL, `status` VARCHAR(16) NOT NULL,
  `operation_id` VARCHAR(100) NOT NULL, PRIMARY KEY (`lease_id`,`period_start`), UNIQUE KEY (`operation_id`),
  FOREIGN KEY (`lease_id`) REFERENCES `qbhousing_leases` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_deposit_deductions` (
  `id` VARCHAR(64) NOT NULL, `lease_id` VARCHAR(64) NOT NULL, `category` VARCHAR(16) NOT NULL,
  `amount` BIGINT UNSIGNED NOT NULL, `approved_amount` BIGINT UNSIGNED NULL,
  `note` TEXT NOT NULL, `decision_note` TEXT NULL, `status` VARCHAR(16) NOT NULL,
  `actor` VARCHAR(50) NOT NULL, `created_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY (`lease_id`,`status`), FOREIGN KEY (`lease_id`) REFERENCES `qbhousing_leases` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_lease_access` (
  `lease_id` VARCHAR(64) NOT NULL, `citizenid` VARCHAR(50) NOT NULL,
  `action` VARCHAR(48) NOT NULL, `allowed` TINYINT(1) NOT NULL,
  PRIMARY KEY (`lease_id`,`citizenid`,`action`), FOREIGN KEY (`lease_id`) REFERENCES `qbhousing_leases` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_stashes` (
  `id` VARCHAR(100) NOT NULL, `property_id` VARCHAR(64) NOT NULL, `lease_id` VARCHAR(64) NULL,
  `tenant` VARCHAR(50) NULL, `status` VARCHAR(16) NOT NULL,
  `coords` LONGTEXT NOT NULL, PRIMARY KEY (`id`), KEY (`property_id`,`status`), KEY (`tenant`,`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_storage_purchases` (
  `property_id` VARCHAR(64) NOT NULL, `tier` INT UNSIGNED NOT NULL,
  `operation_id` VARCHAR(100) NOT NULL, `buyer` VARCHAR(50) NOT NULL,
  PRIMARY KEY (`property_id`,`tier`), UNIQUE KEY (`operation_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_evictions` (
  `lease_id` VARCHAR(64) NOT NULL, `reason` VARCHAR(32) NOT NULL,
  `status` VARCHAR(16) NOT NULL, `created_at` BIGINT NOT NULL,
  PRIMARY KEY (`lease_id`), FOREIGN KEY (`lease_id`) REFERENCES `qbhousing_leases` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_recovery` (
  `id` VARCHAR(100) NOT NULL, `property_id` VARCHAR(64) NOT NULL, `lease_id` VARCHAR(64) NULL,
  `citizenid` VARCHAR(50) NOT NULL, `kind` VARCHAR(16) NOT NULL, `reference` VARCHAR(100) NOT NULL,
  `status` VARCHAR(16) NOT NULL, `created_at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY (`kind`,`reference`,`citizenid`), KEY (`citizenid`,`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_garages` (
  `property_id` VARCHAR(64) NOT NULL, `garage_key` VARCHAR(50) NOT NULL,
  PRIMARY KEY (`property_id`), UNIQUE KEY (`garage_key`),
  FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_garage_recovery` (
  `property_id` VARCHAR(64) NOT NULL, `citizenid` VARCHAR(50) NOT NULL,
  PRIMARY KEY (`property_id`,`citizenid`),
  FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
