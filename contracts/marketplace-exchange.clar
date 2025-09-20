;; Marketplace Exchange Contract
;; Automated market maker for carbon credit trading
;; Provides liquidity pools and trading functionality

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u200))
(define-constant ERR_UNAUTHORIZED (err u201))
(define-constant ERR_INSUFFICIENT_BALANCE (err u202))
(define-constant ERR_INVALID_AMOUNT (err u203))
(define-constant ERR_LISTING_NOT_FOUND (err u204))
(define-constant ERR_LISTING_EXPIRED (err u205))
(define-constant ERR_INSUFFICIENT_LIQUIDITY (err u206))
(define-constant ERR_SLIPPAGE_TOLERANCE (err u207))
(define-constant ERR_PAUSED (err u208))
(define-constant ERR_INVALID_PRICE (err u209))
(define-constant ERR_MINIMUM_LIQUIDITY (err u210))

;; Trading and Fee Constants
(define-constant TRADING_FEE_BASIS_POINTS u30) ;; 0.3% trading fee
(define-constant MINIMUM_LIQUIDITY u1000) ;; Minimum liquidity requirement
(define-constant MAX_SLIPPAGE_BASIS_POINTS u500) ;; 5% max slippage

;; Data Variables
(define-data-var contract-paused bool false)
(define-data-var next-listing-id uint u1)
(define-data-var total-volume uint u0)
(define-data-var liquidity-pool-stx uint u0)
(define-data-var liquidity-pool-tokens uint u0)
(define-data-var total-liquidity-shares uint u0)
(define-data-var platform-fees-collected uint u0)

;; Data Maps
(define-map listings uint {
    seller: principal,
    amount: uint,
    price-per-token: uint,
    total-price: uint,
    expiry-block: uint,
    active: bool,
    filled-amount: uint
})

(define-map user-trades principal {
    total-bought: uint,
    total-sold: uint,
    trade-count: uint,
    last-trade-block: uint
})

(define-map liquidity-providers principal uint)
(define-map user-balances principal uint)

;; Private Functions
(define-private (is-contract-owner)
    (is-eq tx-sender CONTRACT_OWNER))

(define-private (calculate-trading-fee (amount uint))
    (/ (* amount TRADING_FEE_BASIS_POINTS) u10000))

(define-private (min-uint (a uint) (b uint))
    (if (<= a b) a b))

(define-private (calculate-price-with-slippage (base-price uint) (amount uint))
    (let ((slippage-factor (min-uint (/ (* amount u100) (var-get liquidity-pool-tokens)) MAX_SLIPPAGE_BASIS_POINTS)))
        (+ base-price (/ (* base-price slippage-factor) u10000))))

(define-private (update-user-trade-stats (user principal) (amount uint) (is-buy bool))
    (let ((current-stats (default-to {total-bought: u0, total-sold: u0, trade-count: u0, last-trade-block: u0} 
                                   (map-get? user-trades user))))
        (map-set user-trades user {
            total-bought: (if is-buy (+ (get total-bought current-stats) amount) (get total-bought current-stats)),
            total-sold: (if is-buy (get total-sold current-stats) (+ (get total-sold current-stats) amount)),
            trade-count: (+ (get trade-count current-stats) u1),
            last-trade-block: block-height
        })))

(define-private (calculate-liquidity-shares (stx-amount uint) (token-amount uint))
    (if (is-eq (var-get total-liquidity-shares) u0)
        ;; First liquidity provision
        (* stx-amount token-amount)
        ;; Calculate proportional shares
        (min-uint (/ (* stx-amount (var-get total-liquidity-shares)) (var-get liquidity-pool-stx))
                  (/ (* token-amount (var-get total-liquidity-shares)) (var-get liquidity-pool-tokens)))))

;; Read-Only Functions
(define-read-only (get-listing (listing-id uint))
    (map-get? listings listing-id))

(define-read-only (get-current-price)
    (if (and (> (var-get liquidity-pool-stx) u0) (> (var-get liquidity-pool-tokens) u0))
        (ok (/ (* (var-get liquidity-pool-stx) u1000000) (var-get liquidity-pool-tokens)))
        (err ERR_INSUFFICIENT_LIQUIDITY)))

(define-read-only (get-liquidity-pool-info)
    (ok {
        stx-reserves: (var-get liquidity-pool-stx),
        token-reserves: (var-get liquidity-pool-tokens),
        total-shares: (var-get total-liquidity-shares),
        current-price: (unwrap-panic (get-current-price))
    }))

(define-read-only (get-user-trade-stats (user principal))
    (map-get? user-trades user))

(define-read-only (get-user-liquidity-shares (user principal))
    (default-to u0 (map-get? liquidity-providers user)))

(define-read-only (calculate-swap-output (input-amount uint) (input-reserve uint) (output-reserve uint))
    (let ((input-with-fee (- input-amount (calculate-trading-fee input-amount)))
          (numerator (* input-with-fee output-reserve))
          (denominator (+ input-reserve input-with-fee)))
        (/ numerator denominator)))

(define-read-only (get-platform-stats)
    (ok {
        total-volume: (var-get total-volume),
        fees-collected: (var-get platform-fees-collected),
        active-listings: (- (var-get next-listing-id) u1),
        contract-paused: (var-get contract-paused)
    }))

;; Public Functions - Administrative
(define-public (set-contract-paused (paused bool))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (var-set contract-paused paused)
        (ok paused)))

(define-public (withdraw-platform-fees (amount uint) (recipient principal))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (asserts! (<= amount (var-get platform-fees-collected)) ERR_INSUFFICIENT_BALANCE)
        (try! (stx-transfer? amount tx-sender recipient))
        (var-set platform-fees-collected (- (var-get platform-fees-collected) amount))
        (ok amount)))

;; Public Functions - Listing Management
(define-public (create-listing (amount uint) (price-per-token uint) (expiry-blocks uint))
    (let ((listing-id (var-get next-listing-id))
          (total-price (* amount price-per-token))
          (expiry-block (+ block-height expiry-blocks)))
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (> price-per-token u0) ERR_INVALID_PRICE)
        
        ;; Create the listing
        (map-set listings listing-id {
            seller: tx-sender,
            amount: amount,
            price-per-token: price-per-token,
            total-price: total-price,
            expiry-block: expiry-block,
            active: true,
            filled-amount: u0
        })
        
        (var-set next-listing-id (+ listing-id u1))
        (ok listing-id)))

(define-public (cancel-listing (listing-id uint))
    (let ((listing (unwrap! (map-get? listings listing-id) ERR_LISTING_NOT_FOUND)))
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (is-eq (get seller listing) tx-sender) ERR_UNAUTHORIZED)
        (asserts! (get active listing) ERR_LISTING_NOT_FOUND)
        
        (map-set listings listing-id (merge listing {active: false}))
        (ok true)))

;; Public Functions - Trading
(define-public (purchase-from-listing (listing-id uint) (amount uint))
    (let ((listing (unwrap! (map-get? listings listing-id) ERR_LISTING_NOT_FOUND))
          (available-amount (- (get amount listing) (get filled-amount listing)))
          (purchase-price (* amount (get price-per-token listing)))
          (trading-fee (calculate-trading-fee purchase-price)))
        
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (get active listing) ERR_LISTING_NOT_FOUND)
        (asserts! (< block-height (get expiry-block listing)) ERR_LISTING_EXPIRED)
        (asserts! (<= amount available-amount) ERR_INSUFFICIENT_BALANCE)
        
        ;; Transfer STX from buyer to seller
        (try! (stx-transfer? purchase-price tx-sender (get seller listing)))
        
        ;; Collect trading fee
        (try! (stx-transfer? trading-fee tx-sender CONTRACT_OWNER))
        (var-set platform-fees-collected (+ (var-get platform-fees-collected) trading-fee))
        
        ;; Update listing
        (let ((new-filled-amount (+ (get filled-amount listing) amount)))
            (map-set listings listing-id 
                (merge listing {
                    filled-amount: new-filled-amount,
                    active: (< new-filled-amount (get amount listing))
                })))
        
        ;; Update trading statistics
        (update-user-trade-stats tx-sender amount true)
        (update-user-trade-stats (get seller listing) amount false)
        (var-set total-volume (+ (var-get total-volume) purchase-price))
        
        (ok amount)))

;; Public Functions - Automated Market Maker
(define-public (add-liquidity (stx-amount uint) (min-token-amount uint))
    (let ((token-amount (if (is-eq (var-get liquidity-pool-stx) u0)
                           min-token-amount
                           (/ (* stx-amount (var-get liquidity-pool-tokens)) (var-get liquidity-pool-stx))))
          (liquidity-shares (calculate-liquidity-shares stx-amount token-amount)))
        
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (> stx-amount u0) ERR_INVALID_AMOUNT)
        (asserts! (>= token-amount min-token-amount) ERR_SLIPPAGE_TOLERANCE)
        
        ;; Transfer assets to the pool
        (try! (stx-transfer? stx-amount tx-sender CONTRACT_OWNER))
        
        ;; Update pool reserves
        (var-set liquidity-pool-stx (+ (var-get liquidity-pool-stx) stx-amount))
        (var-set liquidity-pool-tokens (+ (var-get liquidity-pool-tokens) token-amount))
        
        ;; Update user's liquidity shares
        (let ((current-shares (get-user-liquidity-shares tx-sender)))
            (map-set liquidity-providers tx-sender (+ current-shares liquidity-shares)))
        
        (var-set total-liquidity-shares (+ (var-get total-liquidity-shares) liquidity-shares))
        (ok liquidity-shares)))

(define-public (remove-liquidity (shares-to-remove uint))
    (let ((user-shares (get-user-liquidity-shares tx-sender))
          (share-percentage (/ (* shares-to-remove u1000000) (var-get total-liquidity-shares)))
          (stx-to-return (/ (* (var-get liquidity-pool-stx) share-percentage) u1000000))
          (tokens-to-return (/ (* (var-get liquidity-pool-tokens) share-percentage) u1000000)))
        
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (<= shares-to-remove user-shares) ERR_INSUFFICIENT_BALANCE)
        (asserts! (>= (- (var-get total-liquidity-shares) shares-to-remove) MINIMUM_LIQUIDITY) ERR_MINIMUM_LIQUIDITY)
        
        ;; Return assets to user
        (try! (stx-transfer? stx-to-return CONTRACT_OWNER tx-sender))
        
        ;; Update pool reserves
        (var-set liquidity-pool-stx (- (var-get liquidity-pool-stx) stx-to-return))
        (var-set liquidity-pool-tokens (- (var-get liquidity-pool-tokens) tokens-to-return))
        
        ;; Update user's liquidity shares
        (map-set liquidity-providers tx-sender (- user-shares shares-to-remove))
        (var-set total-liquidity-shares (- (var-get total-liquidity-shares) shares-to-remove))
        
        (ok {stx-returned: stx-to-return, tokens-returned: tokens-to-return})))

(define-public (swap-stx-for-tokens (stx-amount uint) (min-tokens-out uint))
    (let ((tokens-out (calculate-swap-output stx-amount (var-get liquidity-pool-stx) (var-get liquidity-pool-tokens)))
          (trading-fee (calculate-trading-fee stx-amount)))
        
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (> stx-amount u0) ERR_INVALID_AMOUNT)
        (asserts! (>= tokens-out min-tokens-out) ERR_SLIPPAGE_TOLERANCE)
        (asserts! (<= tokens-out (var-get liquidity-pool-tokens)) ERR_INSUFFICIENT_LIQUIDITY)
        
        ;; Execute swap
        (try! (stx-transfer? stx-amount tx-sender CONTRACT_OWNER))
        
        ;; Update pool reserves
        (var-set liquidity-pool-stx (+ (var-get liquidity-pool-stx) (- stx-amount trading-fee)))
        (var-set liquidity-pool-tokens (- (var-get liquidity-pool-tokens) tokens-out))
        
        ;; Collect fee
        (var-set platform-fees-collected (+ (var-get platform-fees-collected) trading-fee))
        
        ;; Update statistics
        (update-user-trade-stats tx-sender tokens-out true)
        (var-set total-volume (+ (var-get total-volume) stx-amount))
        
        (ok tokens-out)))

(define-public (swap-tokens-for-stx (token-amount uint) (min-stx-out uint))
    (let ((stx-out (calculate-swap-output token-amount (var-get liquidity-pool-tokens) (var-get liquidity-pool-stx)))
          (trading-fee (calculate-trading-fee stx-out)))
        
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (> token-amount u0) ERR_INVALID_AMOUNT)
        (asserts! (>= (- stx-out trading-fee) min-stx-out) ERR_SLIPPAGE_TOLERANCE)
        (asserts! (<= token-amount (var-get liquidity-pool-tokens)) ERR_INSUFFICIENT_LIQUIDITY)
        
        ;; Execute swap - return STX minus trading fee
        (try! (stx-transfer? (- stx-out trading-fee) CONTRACT_OWNER tx-sender))
        
        ;; Update pool reserves
        (var-set liquidity-pool-tokens (+ (var-get liquidity-pool-tokens) token-amount))
        (var-set liquidity-pool-stx (- (var-get liquidity-pool-stx) stx-out))
        
        ;; Collect fee
        (var-set platform-fees-collected (+ (var-get platform-fees-collected) trading-fee))
        
        ;; Update statistics
        (update-user-trade-stats tx-sender token-amount false)
        (var-set total-volume (+ (var-get total-volume) stx-out))
        
        (ok (- stx-out trading-fee))))
