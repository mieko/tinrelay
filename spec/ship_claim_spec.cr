require "./spec_helper"

describe "open ship claims" do
  it "claims an available chosen name without creating a contact" do
    TinrelaySpec.with_server do |root, origin, api|
      ship = Tinrelay::Client.join(
        File.join(root, "first.keyring"), origin, "first-ship",
        "open claim passphrase"
      )

      ship.keyring.data.contacts.should be_empty
      api.database.db.query_one(
        "SELECT name FROM ships WHERE name = ?", "first-ship", as: String
      ).should eq("first-ship")
      api.database.db.scalar("SELECT COUNT(*) FROM relationships").should eq(0)
    end
  end

  it "allows exactly one racing claimant and removes the loser's provisional keys" do
    TinrelaySpec.with_server do |root, origin, api|
      results = Channel(Tuple(Int32, Exception?)).new
      2.times do |index|
        spawn do
          begin
            Tinrelay::Client.join(
              File.join(root, "racer-#{index}.keyring"), origin, "one-name",
              "racing claim passphrase"
            )
            results.send({index, nil})
          rescue ex
            results.send({index, ex})
          end
        end
      end

      outcomes = 2.times.map { TinrelaySpec.receive(results) }.to_a
      outcomes.count { |_, error| error.nil? }.should eq(1)
      loser, error = outcomes.find { |outcome| !outcome[1].nil? }.not_nil!
      error.should be_a(Tinrelay::Conflict)
      File.exists?(File.join(root, "racer-#{loser}.keyring")).should be_false
      File.exists?(File.join(root, "racer-#{loser}.keyring.owner")).should be_false
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ships WHERE name = 'one-name'"
      ).should eq(1)
    end
  end

  it "rejects claims whose ship identity and owner authorization disagree" do
    TinrelaySpec.with_server do |root, origin, api|
      keyring = Tinrelay::Keyring.create(
        File.join(root, "candidate.keyring"), origin, "candidate",
        "invalid claim passphrase"
      )
      certificate = keyring.data.radio!.certificate

      wrong_ship = Tinrelay::ShipClaim.new(
        "substitute", keyring.data.owner_public_key, certificate
      )
      headers = HTTP::Headers{
        "Content-Type"        => "application/json",
        "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
      }
      HTTP::Client.post(
        "#{origin}/v1/join", headers, wrong_ship.to_json
      ).status_code.should eq(400)

      changed_certificate = Tinrelay::ShipRadioCertificate.from_json(certificate.to_json)
      changed_certificate.owner_signature = Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
      invalid_signature = Tinrelay::ShipClaim.new(
        "candidate", keyring.data.owner_public_key, changed_certificate
      )
      HTTP::Client.post(
        "#{origin}/v1/join", headers, invalid_signature.to_json
      ).status_code.should eq(401)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0)
    end
  end
end
