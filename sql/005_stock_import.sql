-- A permanent import marker and lossless source backup. No FK: archiving or
-- removing a native property must never replay its old ownership/keys.
CREATE TABLE IF NOT EXISTS `qbhousing_stock_import` (
  `property_id` VARCHAR(64) NOT NULL,
  `source_data` LONGTEXT NOT NULL,
  `source_sha256` CHAR(64) NOT NULL,
  `imported_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`property_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
