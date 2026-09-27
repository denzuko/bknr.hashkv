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

  Scenario: An empty string is a storable value
    When I put "" into the store
    Then getting that key should return ""

  Scenario: A zero TTL expires the entry immediately
    When I put "short lived" into the store with a TTL of 0 seconds
    Then getting that key should return nothing

  Scenario: Storing a value again after it expired makes it readable again
    When I put "renewed" into the store with a TTL of 0 seconds
    And I put "renewed" into the store again
    Then getting that key should return "renewed"

  Scenario: The content hash ignores the caller's printer settings
    When I put the list 1 2 3 into the store while print length is 2
    And I put the list 1 2 99 into the store while print length is 2
    Then the two list keys should differ

  Scenario: A caller-supplied key shaped like a content hash is rejected
    When I put "forged" under the key of "genuine"
    Then the put should signal a reserved key error

  Scenario: A value with no readable printed form is rejected
    When I put an unreadable object into the store
    Then the put should signal a print error

  Scenario: Concurrent puts of the same value all succeed with one key
    When 8 threads put "contended" into the store at once
    Then no put should have signalled an error
    And every put should have returned the same key

  Scenario: A stored value survives a store restart
    When I put "durable" into the store
    And the store is closed and reopened
    Then getting that key should return "durable"

  Scenario: A CLOS instance is stored and read back with its slots
    When I put an effect named "fireball" with damage 12 into the store
    Then getting that key should return an effect named "fireball" with damage 12

  Scenario: A struct is stored under a caller-supplied key
    When I put a struct effect with damage 7 under the key "fx:1"
    Then getting "fx:1" should return a struct effect with damage 7

  Scenario: A CLOS instance survives a store restart
    When I put an effect named "frost" with damage 3 into the store
    And the store is closed and reopened
    Then getting that key should return an effect named "frost" with damage 3

  Scenario: Equal CLOS instances share one key
    When I put an effect named "heal" with damage 0 into the store
    And I put an effect named "heal" with damage 0 into the store again
    Then both puts should return the same key

  Scenario: Changing a value after storing it does not change the stored value
    When I put the list 1 2 3 into the store and then change its last element to 99
    Then getting that key should return the list 1 2 3

  Scenario: Changing a value read from the store does not change the stored value
    When I put the list 1 2 3 into the store
    And I change the last element of the list read from the store to 99
    Then getting that key should return the list 1 2 3

  Scenario: A function is rejected as a value
    When I put a function into the store
    Then the put should signal an unstorable value error

  Scenario: A value that contains itself is rejected
    When I put a circular list into the store
    Then the put should signal an unstorable value error
