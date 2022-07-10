module 0x2::Token {
    struct Coin<AssetType: copy + drop> has store {
        type: AssetType,
        value: u64,
    }

    // control the minting/creation in the defining module of `ATy`
    public fun create<ATy: copy + drop>(type: ATy, value: u64): Coin<ATy> {
        Coin { type, value }
    }

    public fun value<ATy: copy + drop>(coin: &Coin<ATy>): u64 {
        coin.value
    }

    public fun split<ATy: copy + drop>(coin: Coin<ATy>, amount: u64): (Coin<ATy>, Coin<ATy>) {
        let other = withdraw(&mut coin, amount);
        (coin, other)
    }

    public fun withdraw<ATy: copy + drop>(coin: &mut Coin<ATy>, amount: u64): Coin<ATy> {
        assert!(coin.value >= amount, 10);
        coin.value = coin.value - amount;
        Coin { type: *&coin.type, value: amount }
    }

    public fun join<ATy: copy + drop>(xus: Coin<ATy>, coin2: Coin<ATy>): Coin<ATy> {
        deposit(&mut xus, coin2);
        xus
    }

    public fun deposit<ATy: copy + drop>(coin: &mut Coin<ATy>, check: Coin<ATy>) {
        let Coin { value, type } = check;
        assert!(&coin.type == &type, 42);
        coin.value = coin.value + value;
    }

    public fun destroy_zero<ATy: copy + drop>(coin: Coin<ATy>) {
        let Coin { value, type: _ } = coin;
        assert!(value == 0, 11)
    }
}

module Aubrium::XYKAMM {
    use Std::Signer;

    use 0x2::Token;
    
    const MINIMUM_LIQUIDITY: u64 = 1000;

    struct Pair<Asset0Type: copy + drop, Asset1Type: copy + drop> has key {
        coin0: Token::Coin<Asset0Type>,
        coin1: Token::Coin<Asset1Type>,
        total_supply: u64,
        burnt_liquidity: Token::Coin<LiquidityAsset<Asset0Type, Asset1Type>>
    }

    struct LiquidityAsset<phantom Asset0Type: copy + drop, phantom Asset1Type: copy + drop> has copy, drop, store {
        pool_owner: address
    }

    public fun accept<Asset0Type: copy + drop + store, Asset1Type: copy + drop + store>(pool_owner: &signer, coin0: Token::Coin<Asset0Type>, coin1: Token::Coin<Asset1Type>) {
        // make sure pair does not exist already
        let pool_owner_address = Signer::address_of(pool_owner);
        assert!(!exists<Pair<Asset0Type, Asset1Type>>(pool_owner_address), 1000); // PAIR_ALREADY_EXISTS
        assert!(!exists<Pair<Asset1Type, Asset0Type>>(pool_owner_address), 1000); // PAIR_ALREADY_EXISTS

        // create and store new pair
        move_to(pool_owner, Pair<Asset0Type, Asset1Type> {
            coin0,
            coin1,
            total_supply: 0,
            burnt_liquidity: Token::create<LiquidityAsset<Asset0Type, Asset1Type>>(LiquidityAsset<Asset0Type, Asset1Type> { pool_owner: pool_owner_address }, 0)
        })
    }

    fun min(x: u64, y: u64): u64 {
        if (x < y) x else y
    }
    
    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    fun sqrt(y: u64): u64 {
        if (y > 3) {
            let z = y;
            let x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            };
            return z
        };
        if (y > 0) 1 else 0
    }

    public fun mint<Asset0Type: copy + drop + store, Asset1Type: copy + drop + store>(pool_owner: address, coin0: Token::Coin<Asset0Type>, coin1: Token::Coin<Asset1Type>): Token::Coin<LiquidityAsset<Asset0Type, Asset1Type>>
        acquires Pair
    {
        // get pair reserves
        assert!(exists<Pair<Asset0Type, Asset1Type>>(pool_owner), 1006); // PAIR_DOES_NOT_EXIST
        let pair = borrow_global_mut<Pair<Asset0Type, Asset1Type>>(pool_owner);
        let reserve0 = Token::value(&pair.coin0);
        let reserve1 = Token::value(&pair.coin1);

        // get deposited amounts
        let amount0 = Token::value(&coin0);
        let amount1 = Token::value(&coin1);
        
        // calc liquidity to mint from deposited amounts
        let liquidity;

        if (pair.total_supply == 0) {
            liquidity = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;

            // permanently lock the first MINIMUM_LIQUIDITY tokens
            let total_supply_ref = &mut pair.total_supply;
            *total_supply_ref = *total_supply_ref + MINIMUM_LIQUIDITY;
        } else {
            liquidity = min(amount0 * pair.total_supply / reserve0, amount1 * pair.total_supply / reserve1);
        };

        assert!(liquidity > 0, 1001); // INSUFFICIENT_LIQUIDITY_MINTED
        
        // deposit tokens
        Token::deposit(&mut pair.coin0, coin0);
        Token::deposit(&mut pair.coin1, coin1);
        
        // mint liquidity and return it
        let total_supply_ref = &mut pair.total_supply;
        *total_supply_ref = *total_supply_ref + liquidity;
        Token::create<LiquidityAsset<Asset0Type, Asset1Type>>(LiquidityAsset<Asset0Type, Asset1Type> { pool_owner }, liquidity)
    }

    public fun burn<Asset0Type: copy + drop + store, Asset1Type: copy + drop + store>(pool_owner: address, liquidity: Token::Coin<LiquidityAsset<Asset0Type, Asset1Type>>): (Token::Coin<Asset0Type>, Token::Coin<Asset1Type>)
        acquires Pair
    {
        // get pair reserves
        assert!(exists<Pair<Asset0Type, Asset1Type>>(pool_owner), 1006); // PAIR_DOES_NOT_EXIST
        let pair = borrow_global_mut<Pair<Asset0Type, Asset1Type>>(pool_owner);
        let reserve0 = Token::value(&pair.coin0);
        let reserve1 = Token::value(&pair.coin1);
        
        // get amounts to withdraw from burnt liquidity
        let liquidity_value = Token::value(&liquidity);
        let amount0 = liquidity_value * reserve0 / pair.total_supply; // using balances ensures pro-rata distribution
        let amount1 = liquidity_value * reserve1 / pair.total_supply; // using balances ensures pro-rata distribution
        assert!(amount0 > 0 && amount1 > 0, 1002); // INSUFFICIENT_LIQUIDITY_BURNED
        
        // burn liquidity
        Token::deposit(&mut pair.burnt_liquidity, liquidity);
        let total_supply_ref = &mut pair.total_supply;
        *total_supply_ref = *total_supply_ref - liquidity_value;
        
        // withdraw tokens and return
        (Token::withdraw(&mut pair.coin0, amount0), Token::withdraw(&mut pair.coin1, amount1))
    }

    public fun swap<In: copy + drop + store, Out: copy + drop + store>(pool_owner: address, coin_in: Token::Coin<In>, amount_out_min: u64): Token::Coin<Out>
        acquires Pair
    {
        // get amount in
        let amount_in = Token::value(&coin_in);

        // get amount out + deposit + withdraw
        if (exists<Pair<In, Out>>(pool_owner)) {
            // get pair reserves
            let pair = borrow_global_mut<Pair<In, Out>>(pool_owner);
            let reserve_in = Token::value(&pair.coin0);
            let reserve_out = Token::value(&pair.coin1);

            // get amount out
            let amount_out = get_amount_out_internal(reserve_in, reserve_out, amount_in);

            // validation
            assert!(amount_out > 0 && amount_out >= amount_out_min, 1004); // INSUFFICIENT_OUTPUT_AMOUNT
            assert!(amount_out < reserve_out, 1005); // INSUFFICIENT_LIQUIDITY
        
            // deposit input token, withdraw output tokens, and return them
            Token::deposit(&mut pair.coin0, coin_in);
            Token::withdraw(&mut pair.coin1, amount_out)
        } else {
            // assert pair exists
            assert!(exists<Pair<Out, In>>(pool_owner), 1006); // PAIR_DOES_NOT_EXIST

            // get pair reserves
            let pair = borrow_global_mut<Pair<Out, In>>(pool_owner);
            let reserve_in = Token::value(&pair.coin1);
            let reserve_out = Token::value(&pair.coin0);

            // get amount out
            let amount_out = get_amount_out_internal(reserve_in, reserve_out, amount_in);

            // validation
            assert!(amount_out > 0 && amount_out >= amount_out_min, 1004); // INSUFFICIENT_OUTPUT_AMOUNT
            assert!(amount_out < reserve_out, 1005); // INSUFFICIENT_LIQUIDITY

            // deposit input token, withdraw output tokens, and return them
            Token::deposit(&mut pair.coin1, coin_in);
            Token::withdraw(&mut pair.coin0, amount_out)
        }
    }

    public fun swap_to<In: copy + drop + store, Out: copy + drop + store>(pool_owner: address, coin_in: &mut Token::Coin<In>, amount_out: u64): Token::Coin<Out>
        acquires Pair
    {
        let amount_in = get_amount_in<In, Out>(pool_owner, amount_out);
        let coin_in_swap = Token::withdraw(coin_in, amount_in);
        swap<In, Out>(pool_owner, coin_in_swap, amount_out)
    }

    fun get_reserves<In: copy + drop + store, Out: copy + drop + store>(pool_owner: address): (u64, u64)
        acquires Pair
    {
        let reserve_in;
        let reserve_out;

        if (exists<Pair<In, Out>>(pool_owner)) {
            let pair = borrow_global_mut<Pair<In, Out>>(pool_owner);
            reserve_in = Token::value(&pair.coin0);
            reserve_out = Token::value(&pair.coin1);
        } else {
            assert!(exists<Pair<Out, In>>(pool_owner), 1006); // PAIR_DOES_NOT_EXIST
            let pair = borrow_global_mut<Pair<Out, In>>(pool_owner);
            reserve_in = Token::value(&pair.coin1);
            reserve_out = Token::value(&pair.coin0);
        };

        (reserve_in, reserve_out)
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    fun get_amount_out_internal(reserve_in: u64, reserve_out: u64, amount_in: u64): u64 {
        // validation
        assert!(amount_in > 0, 1004); // INSUFFICIENT_INPUT_AMOUNT
        assert!(reserve_in > 0 && reserve_out > 0, 1005); // INSUFFICIENT_LIQUIDITY

        // calc amount out
        let amount_in_with_fee = amount_in * 997;
        let numerator = amount_in_with_fee * reserve_out;
        let denominator = (reserve_in * 1000) + amount_in_with_fee;
        numerator / denominator
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    public fun get_amount_out<In: copy + drop + store, Out: copy + drop + store>(pool_owner: address, amount_in: u64): u64
        acquires Pair
    {
        // get pair reserves
        let (reserve_in, reserve_out) = get_reserves<In, Out>(pool_owner);

        // return amount out
        get_amount_out_internal(reserve_in, reserve_out, amount_in)
    }

    // given an output amount of an asset, returns a required input amount of the other asset
    public fun get_amount_in<In: copy + drop + store, Out: copy + drop + store>(pool_owner: address, amount_out: u64): u64
        acquires Pair
    {
        // validation
        assert!(amount_out > 0, 1004); // INSUFFICIENT_OUTPUT_AMOUNT

        // get pair reserves
        let (reserve_in, reserve_out) = get_reserves<In, Out>(pool_owner);
        assert!(reserve_in > 0 && reserve_out > 0, 1005); // INSUFFICIENT_LIQUIDITY

        // calc amount in
        let numerator = reserve_in * amount_out * 1000;
        let denominator = reserve_out - (amount_out * 997);
        (numerator / denominator) + 1
    }

    // returns 1 if found Pair<Asset0Type, Asset1Type>, 2 if found Pair<Asset1Type, Asset0Type>, or 0 if pair does not exist
    // for use with mint and burn functions--we must know the correct pair asset ordering
    public fun find_pair<Asset0Type: copy + drop + store, Asset1Type: copy + drop + store>(pool_owner: address): u8 {
        if (exists<Pair<Asset0Type, Asset1Type>>(pool_owner)) return 1;
        if (exists<Pair<Asset1Type, Asset0Type>>(pool_owner)) return 2;
        0
    }
}
