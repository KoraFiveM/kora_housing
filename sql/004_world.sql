CREATE TABLE IF NOT EXISTS `qbhousing_spaces` (
  `property_id` VARCHAR(64) NOT NULL, `definition` LONGTEXT NOT NULL, `revision` INT UNSIGNED NOT NULL,
  PRIMARY KEY (`property_id`),
  CONSTRAINT `fk_qbhousing_space_property` FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_furniture` (
  `id` VARCHAR(64) NOT NULL, `property_id` VARCHAR(64) NOT NULL, `owner_cid` VARCHAR(50) NOT NULL,
  `lease_id` VARCHAR(64) NULL, `status` VARCHAR(16) NOT NULL, `definition` LONGTEXT NOT NULL,
  `revision` INT UNSIGNED NOT NULL, PRIMARY KEY (`id`),
  KEY `idx_qbhousing_furniture_property` (`property_id`,`status`),
  KEY `idx_qbhousing_furniture_recovery` (`owner_cid`,`status`),
  CONSTRAINT `fk_qbhousing_furniture_property` FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_cameras` (
  `id` VARCHAR(64) NOT NULL, `property_id` VARCHAR(64) NOT NULL, `definition` LONGTEXT NOT NULL,
  `revision` INT UNSIGNED NOT NULL, PRIMARY KEY (`id`), KEY `idx_qbhousing_camera_property` (`property_id`),
  CONSTRAINT `fk_qbhousing_camera_property` FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_camera_grants` (
  `property_id` VARCHAR(64) NOT NULL, `citizenid` VARCHAR(50) NOT NULL, `expires_at` BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (`property_id`,`citizenid`),
  CONSTRAINT `fk_qbhousing_camera_grant_property` FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `qbhousing_alarms` (
  `property_id` VARCHAR(64) NOT NULL, `definition` LONGTEXT NOT NULL, `revision` INT UNSIGNED NOT NULL,
  PRIMARY KEY (`property_id`),
  CONSTRAINT `fk_qbhousing_alarm_property` FOREIGN KEY (`property_id`) REFERENCES `qbhousing_properties` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
