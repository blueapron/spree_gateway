require 'spec_helper'

describe Spree::Gateway::StripeGateway do
  let(:secret_key) { 'key' }
  let(:email) { 'customer@example.com' }

  let(:payment) {
    double('Spree::Payment',
      source: Spree::CreditCard.new,
      order: double('Spree::Order',
        email: email,
        bill_address: bill_address
      )
    )
  }

  let(:provider) do
    double('provider').tap do |p|
      allow(p).to receive(:purchase)
      allow(p).to receive(:authorize)
      allow(p).to receive(:capture)
    end
  end

  before do
    subject.preferences = { secret_key: secret_key }
    allow(subject).to receive(:options_for_purchase_or_auth) { ['money','cc','opts'] }
    allow(subject).to receive(:provider) { provider }
  end

  describe '#create_profile' do
    before do
      allow(payment.source).to receive(:update_attributes!)
    end

    context 'when Stripe returns a response' do
      let(:bill_address) { nil }
      let(:stripe_response_params) do
        {
          'id' => 'cus_FOO',
          'default_card' => 'card_BAR',
          'cards' => {
            'data' => [
              {
                "id"=>"card_BAR",
                "object"=>"card",
                "last4"=>"4242",
                "brand"=>"Visa",
                "funding"=>"credit",
                "exp_month"=>1,
                "exp_year"=>2019,
                "fingerprint"=>"H2k64481Ex8hSCgC",
                "country"=>"US",
                "name"=>"Mister Spree",
                "address_line1"=>"123 Street",
                "address_city"=>"New York",
                "address_state"=>"New York",
                "address_zip"=>"12345",
                "address_country"=>"United States",
                "cvc_check"=>"pass",
                "address_line1_check"=>"pass",
                "address_zip_check"=>"pass",
                "dynamic_last4"=>nil,
                "customer"=>"cus_FOO",
                "type"=>"Visa"
              },
              {
                "id" => "some other card"
              }
            ]
          }
        }
      end

      let(:stripe_response) { double(params: stripe_response_params, success?: true) }

      before do
        expect(subject.provider).to receive(:store) { stripe_response }
      end

      it 'populates payment source with Stripe active_card information' do
        expect(payment.source).to receive(:update_attributes!).with(
          hash_including(
            last_digits: '4242',
            month: 1,
            year: 2019,
            name: 'Mister Spree',
            gateway_customer_profile_id: 'cus_FOO',
            gateway_payment_profile_id: 'card_BAR'
          )
        )
        subject.create_profile payment
      end
    end

    context 'with an order that has a bill address' do
      let(:bill_address) {
        double('Spree::Address',
          address1: '123 Happy Road',
          address2: 'Apt 303',
          city: 'Suzarac',
          zipcode: '95671',
          state: double('Spree::State', name: 'Oregon'),
          country: double('Spree::Country', name: 'United States')
        )
      }

      it 'stores the bill address with the provider' do
        subject.provider.should_receive(:store).with(payment.source, {
          email: email,
          login: secret_key,

          address: {
            address1: '123 Happy Road',
            address2: 'Apt 303',
            city: 'Suzarac',
            zip: '95671',
            state: 'Oregon',
            country: 'United States'
          }
        }).and_return double.as_null_object

        subject.create_profile payment
      end
    end

    context 'with an order that does not have a bill address' do
      let(:bill_address) { nil }

      it 'does not store a bill address with the provider' do
        subject.provider.should_receive(:store).with(payment.source, {
          email: email,
          login: secret_key,
        }).and_return double.as_null_object

        subject.create_profile payment
      end

      # Regression test for #141
      context "correcting the card type" do
        before do
          # We don't care about this method for these tests
          allow(subject.provider).to receive(:store) { double.as_null_object }
        end

        it "converts 'American Express' to 'american_express'" do
          payment.source.cc_type = 'American Express'
          subject.create_profile(payment)
          expect(payment.source.cc_type).to eq('american_express')
        end

        it "converts 'Diners Club' to 'diners_club'" do
          payment.source.cc_type = 'Diners Club'
          subject.create_profile(payment)
          expect(payment.source.cc_type).to eq('diners_club')
        end

        it "converts 'Visa' to 'visa'" do
          payment.source.cc_type = 'Visa'
          subject.create_profile(payment)
          expect(payment.source.cc_type).to eq('visa')
        end
      end
    end
  end

  context 'purchasing' do
    after do
      subject.purchase(19.99, 'credit card', {})
    end

    it 'send the payment to the provider' do
      provider.should_receive(:purchase).with('money','cc','opts')
    end
  end

  context 'authorizing' do
    after do
      subject.authorize(19.99, 'credit card', {})
    end

    it 'send the authorization to the provider' do
      provider.should_receive(:authorize).with('money','cc','opts')
    end
  end

  context 'capturing' do

    after do
      subject.capture(1234, 'response_code', {})
    end

    it 'convert the amount to cents' do
      provider.should_receive(:capture).with(1234,anything,anything)
    end

    it 'use the response code as the authorization' do
      provider.should_receive(:capture).with(anything,'response_code',anything)
    end
  end

  context 'capture with payment class' do
    let(:gateway) do
      gateway = described_class.new(:environment => 'test', :active => true)
      gateway.set_preference :secret_key, secret_key
      allow(gateway).to receive(:options_for_purchase_or_auth) { ['money','cc','opts'] }
      allow(gateway).to receive(:provider) { provider }
      allow(gateway).to receive(:source_required) { true }
      gateway
    end

    let(:order) { Spree::Order.create }

    let(:card) do
      mock_model(Spree::CreditCard, :number => "4111111111111111",
                                    :has_payment_profile? => true)
    end

    let(:payment) do
      payment = Spree::Payment.new
      payment.source = card
      payment.order = order
      payment.payment_method = gateway
      payment.amount = 98.55
      payment.state = 'pending'
      payment.response_code = '12345'
      payment
    end

    let!(:success_response) do
      double('success_response', :success? => true,
                               :authorization => '123',
                               :avs_result => { 'code' => 'avs-code' },
                               :cvv_result => { 'code' => 'cvv-code', 'message' => "CVV Result"})
    end

    after do
      payment.capture!
    end

    it 'gets correct amount' do
      expect(provider).to receive(:capture).with(9855,'12345',anything) { success_response }
    end
  end
end
