ALTER TABLE `qbhousing_properties` ADD COLUMN IF NOT EXISTS `property_type` VARCHAR(24) NOT NULL DEFAULT 'legacy';
ALTER TABLE `qbhousing_properties` ADD COLUMN IF NOT EXISTS `revision` INT UNSIGNED NOT NULL DEFAULT 0;
ALTER TABLE `qbhousing_properties` ADD COLUMN IF NOT EXISTS `ownership_revision` INT UNSIGNED NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS `qbhousing_legacy_backup` (
  `property_id` VARCHAR(64) NOT NULL,
  `owner` VARCHAR(50) NULL,
  `definition` LONGTEXT NOT NULL,
  `definition_sha256` CHAR(64) NOT NULL,
  `captured_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`property_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_coowners` (
  `property_id` VARCHAR(64) NOT NULL,
  `citizenid` VARCHAR(50) NOT NULL,
  PRIMARY KEY (`property_id`, `citizenid`),
  KEY `idx_qbhousing_coowner` (`citizenid`),
  CONSTRAINT `fk_qbhousing_coowners_property` FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_permissions` (
  `property_id` VARCHAR(64) NOT NULL,
  `citizenid` VARCHAR(50) NOT NULL,
  `action` VARCHAR(48) NOT NULL,
  `allowed` TINYINT(1) NOT NULL,
  PRIMARY KEY (`property_id`, `citizenid`, `action`),
  KEY `idx_qbhousing_permission_subject` (`citizenid`),
  CONSTRAINT `fk_qbhousing_permissions_property` FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_units` (
  `property_id` VARCHAR(64) NOT NULL,
  `parent_id` VARCHAR(64) NOT NULL,
  `unit_label` VARCHAR(50) NULL,
  PRIMARY KEY (`property_id`),
  KEY `idx_qbhousing_unit_parent` (`parent_id`),
  CONSTRAINT `fk_qbhousing_unit_property` FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`),
  CONSTRAINT `fk_qbhousing_unit_parent` FOREIGN KEY (`parent_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_audit` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `property_id` VARCHAR(64) NOT NULL,
  `actor` VARCHAR(50) NULL,
  `action` VARCHAR(48) NOT NULL,
  `target` VARCHAR(50) NULL,
  `outcome` VARCHAR(16) NOT NULL,
  `context` LONGTEXT NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_qbhousing_audit_property` (`property_id`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
