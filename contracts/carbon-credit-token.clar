;; Carbon Credit Token Contract
;; ERC-20 compatible token representing verified carbon credits
;; Implements SIP-10 standard for fungible tokens on Stacks

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_UNAUTHORIZED (err u103))
(define-constant ERR_PAUSED (err u104))
(define-constant ERR_CREDIT_NOT_FOUND (err u105))
(define-constant ERR_CREDIT_ALREADY_VERIFIED (err u106))
(define-constant ERR_INVALID_RECIPIENT (err u107))

;; Token Properties
(define-fungible-token carbon-credit)
(define-data-var token-name (string-ascii 32) "Carbon Credit Token")
(define-data-var token-symbol (string-ascii 10) "CCT")
(define-data-var token-decimals uint u6)
(define-data-var contract-paused bool false)
(define-data-var total-credits-issued uint u0)

;; Data Maps
(define-map authorized-minters principal bool)
(define-map credit-metadata uint {
    issuer: principal,
    project-id: (string-ascii 64),
    vintage: uint,
    verification-standard: (string-ascii 32),
    verified: bool,
    retired: bool,
    issue-date: uint
})

(define-map user-balances principal uint)
(define-map allowances {owner: principal, spender: principal} uint)

;; Private Functions
(define-private (is-contract-owner)
    (is-eq tx-sender CONTRACT_OWNER))

(define-private (is-authorized-minter (user principal))
    (default-to false (map-get? authorized-minters user)))

(define-private (mint-internal (amount uint) (recipient principal))
    (begin
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (not (is-eq recipient tx-sender)) ERR_INVALID_RECIPIENT)
        (try! (ft-mint? carbon-credit amount recipient))
        (var-set total-credits-issued (+ (var-get total-credits-issued) amount))
        (ok amount)))

(define-private (burn-internal (amount uint) (holder principal))
    (begin
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (>= (ft-get-balance carbon-credit holder) amount) ERR_INSUFFICIENT_BALANCE)
        (try! (ft-burn? carbon-credit amount holder))
        (ok amount)))

;; Read-Only Functions
(define-read-only (get-name)
    (ok (var-get token-name)))

(define-read-only (get-symbol)
    (ok (var-get token-symbol)))

(define-read-only (get-decimals)
    (ok (var-get token-decimals)))

(define-read-only (get-balance (user principal))
    (ok (ft-get-balance carbon-credit user)))

(define-read-only (get-total-supply)
    (ok (ft-get-supply carbon-credit)))

(define-read-only (get-total-credits-issued)
    (ok (var-get total-credits-issued)))

(define-read-only (is-paused)
    (ok (var-get contract-paused)))

(define-read-only (get-credit-metadata (credit-id uint))
    (map-get? credit-metadata credit-id))

(define-read-only (is-credit-verified (credit-id uint))
    (match (map-get? credit-metadata credit-id)
        metadata (ok (get verified metadata))
        (err ERR_CREDIT_NOT_FOUND)))

(define-read-only (get-allowance (owner principal) (spender principal))
    (ok (default-to u0 (map-get? allowances {owner: owner, spender: spender}))))

;; Public Functions - Administrative
(define-public (set-contract-paused (paused bool))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (var-set contract-paused paused)
        (ok paused)))

(define-public (add-authorized-minter (minter principal))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (map-set authorized-minters minter true)
        (ok true)))

(define-public (remove-authorized-minter (minter principal))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (map-delete authorized-minters minter)
        (ok true)))

;; Public Functions - Token Operations
(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
    (begin
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (or (is-eq tx-sender sender) (is-eq tx-sender CONTRACT_OWNER)) ERR_UNAUTHORIZED)
        (try! (ft-transfer? carbon-credit amount sender recipient))
        (match memo to-print (print to-print) 0x)
        (ok true)))

(define-public (mint (amount uint) (recipient principal))
    (begin
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (or (is-contract-owner) (is-authorized-minter tx-sender)) ERR_UNAUTHORIZED)
        (mint-internal amount recipient)))

(define-public (burn (amount uint))
    (begin
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (burn-internal amount tx-sender)))

(define-public (approve (spender principal) (amount uint))
    (begin
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (map-set allowances {owner: tx-sender, spender: spender} amount)
        (ok true)))

(define-public (transfer-from (amount uint) (owner principal) (recipient principal))
    (let ((current-allowance (unwrap! (get-allowance owner tx-sender) ERR_INSUFFICIENT_BALANCE)))
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (>= current-allowance amount) ERR_INSUFFICIENT_BALANCE)
        (try! (ft-transfer? carbon-credit amount owner recipient))
        (map-set allowances {owner: owner, spender: tx-sender} (- current-allowance amount))
        (ok true)))

;; Carbon Credit Specific Functions
(define-public (issue-carbon-credit (credit-id uint) (amount uint) (recipient principal) 
                                   (project-id (string-ascii 64)) (vintage uint) 
                                   (verification-standard (string-ascii 32)))
    (begin
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (or (is-contract-owner) (is-authorized-minter tx-sender)) ERR_UNAUTHORIZED)
        (asserts! (is-none (map-get? credit-metadata credit-id)) ERR_CREDIT_ALREADY_VERIFIED)
        
        ;; Store credit metadata
        (map-set credit-metadata credit-id {
            issuer: tx-sender,
            project-id: project-id,
            vintage: vintage,
            verification-standard: verification-standard,
            verified: false,
            retired: false,
            issue-date: block-height
        })
        
        ;; Mint tokens
        (mint-internal amount recipient)))

(define-public (verify-carbon-credit (credit-id uint))
    (let ((credit-data (unwrap! (map-get? credit-metadata credit-id) ERR_CREDIT_NOT_FOUND)))
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (asserts! (not (get verified credit-data)) ERR_CREDIT_ALREADY_VERIFIED)
        
        (map-set credit-metadata credit-id 
            (merge credit-data {verified: true}))
        (ok true)))

(define-public (retire-carbon-credit (credit-id uint) (amount uint))
    (let ((credit-data (unwrap! (map-get? credit-metadata credit-id) ERR_CREDIT_NOT_FOUND)))
        (asserts! (not (var-get contract-paused)) ERR_PAUSED)
        (asserts! (get verified credit-data) ERR_UNAUTHORIZED)
        (asserts! (not (get retired credit-data)) ERR_UNAUTHORIZED)
        
        ;; Mark credit as retired
        (map-set credit-metadata credit-id 
            (merge credit-data {retired: true}))
        
        ;; Burn the tokens to represent retirement
        (burn-internal amount tx-sender)))

;; Initialize contract
(begin
    (map-set authorized-minters CONTRACT_OWNER true)
    (ok true))
