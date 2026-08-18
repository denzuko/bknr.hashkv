Feature: Content-addressable key/value storage
  As a caller of bknr.hashkv
  I want values stored and retrieved by their content hash
  So that identical values are never duplicated on disk

  Background:
    Given a fresh bknr.hashkv store

  Scenario: Storing a value returns its content hash
    When I put "hello world" into the store
    Then I should get back a hash key

  Scenario: A stored value can be retrieved by its hash
    When I put "hello world" into the store
    Then getting that key should return "hello world"

  Scenario: Storing the same value twice returns the same key
    When I put "duplicate" into the store
    And I put "duplicate" into the store again
    Then both puts should return the same key

  Scenario: Deleting a value removes it from the store
    When I put "temporary" into the store
    And I delete that key
    Then getting that key should return nothing

  Scenario: Getting a key that was never stored returns nothing
    When I get a key that was never stored
    Then getting that key should return nothing
