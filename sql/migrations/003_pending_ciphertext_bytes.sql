CREATE INDEX pending_ciphertext_bytes
  ON transmissions(state, LENGTH(ciphertext))
  WHERE state = 'pending';
