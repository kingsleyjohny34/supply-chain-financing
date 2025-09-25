;; Supply Chain Finance System
;; Verify purchase orders, provide financing, and manage repayments from suppliers
;; Working capital financing based on verified trade documents

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ORDER-NOT-FOUND (err u101))
(define-constant ERR-ORDER-EXISTS (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-INVALID-STATUS (err u104))
(define-constant ERR-FINANCING-EXISTS (err u105))
(define-constant ERR-PAYMENT-FAILED (err u106))
(define-constant ERR-NOT-VERIFIED (err u107))
(define-constant ERR-EXPIRED (err u108))
(define-constant ERR-DELIVERY-PENDING (err u109))

;; Order status constants
(define-constant ORDER-SUBMITTED u1)
(define-constant ORDER-VERIFIED u2)
(define-constant ORDER-FINANCED u3)
(define-constant ORDER-DELIVERED u4)
(define-constant ORDER-PAID u5)
(define-constant ORDER-DEFAULTED u6)

;; Financing status constants
(define-constant FINANCING-ACTIVE u1)
(define-constant FINANCING-REPAID u2)
(define-constant FINANCING-DEFAULTED u3)

;; data maps and vars
;; Purchase order registry
(define-map purchase-orders
  { order-id: (string-ascii 64) }
  {
    supplier: principal,
    buyer: principal,
    amount: uint,
    description: (string-ascii 512),
    delivery-date: uint,
    payment-terms: uint, ;; Days
    verification-hash: (string-ascii 128),
    status: uint,
    created-at: uint,
    verified-at: (optional uint),
    delivered-at: (optional uint),
    paid-at: (optional uint)
  }
)

;; Financing agreements
(define-map financing-agreements
  { agreement-id: (string-ascii 64) }
  {
    order-id: (string-ascii 64),
    financier: principal,
    supplier: principal,
    principal-amount: uint,
    interest-rate: uint, ;; Basis points
    term-days: uint,
    advance-rate: uint, ;; Percentage of order value
    total-repayment: uint,
    amount-repaid: uint,
    status: uint,
    funded-at: uint,
    due-date: uint,
    collateral-value: uint
  }
)

;; Participant profiles
(define-map participants
  { participant: principal }
  {
    name: (string-ascii 128),
    participant-type: uint, ;; 1=Supplier, 2=Buyer, 3=Financier
    credit-rating: uint,
    total-transactions: uint,
    successful-transactions: uint,
    total-financed: uint,
    reputation-score: uint,
    verified: bool,
    joined-at: uint
  }
)

;; Payment history
(define-map payment-records
  { agreement-id: (string-ascii 64), payment-index: uint }
  {
    amount: uint,
    payment-date: uint,
    principal-portion: uint,
    interest-portion: uint,
    fee-portion: uint,
    remaining-balance: uint
  }
)

;; Risk assessment data
(define-map risk-assessments
  { assessment-id: (string-ascii 64) }
  {
    order-id: (string-ascii 64),
    supplier-score: uint,
    buyer-score: uint,
    order-score: uint,
    overall-risk: uint,
    recommended-rate: uint,
    max-advance-rate: uint,
    assessed-by: principal,
    assessed-at: uint
  }
)

;; Platform statistics
(define-data-var next-order-id uint u1)
(define-data-var next-agreement-id uint u1)
(define-data-var total-orders uint u0)
(define-data-var total-financed-amount uint u0)
(define-data-var total-repaid-amount uint u0)
(define-data-var platform-fee-rate uint u200) ;; 2%
(define-data-var default-interest-rate uint u1200) ;; 12% annually

;; private functions
;; Calculate financing terms based on risk assessment
(define-private (calculate-financing-terms
    (order-amount uint)
    (supplier principal)
    (buyer principal)
    (term-days uint))
  (let (
    (supplier-rating (get-participant-credit-rating supplier))
    (buyer-rating (get-participant-credit-rating buyer))
    (risk-factor (/ (+ supplier-rating buyer-rating) u2))
    (base-rate (var-get default-interest-rate))
    (risk-adjustment (if (< risk-factor u600) u300 (if (< risk-factor u750) u100 u0)))
    (final-rate (+ base-rate risk-adjustment))
    (advance-rate (if (>= risk-factor u750) u80 (if (>= risk-factor u650) u70 u60)))
  )
    {
      interest-rate: final-rate,
      advance-rate: advance-rate,
      principal-amount: (/ (* order-amount advance-rate) u100),
      total-repayment: (+ order-amount (/ (* order-amount final-rate term-days) u36500))
    }
  )
)

;; Get participant credit rating
(define-private (get-participant-credit-rating (participant principal))
  (match (map-get? participants {participant: participant})
    profile (get credit-rating profile)
    u500 ;; Default rating for new participants
  )
)

;; Update participant statistics
(define-private (update-participant-stats
    (participant principal)
    (transaction-amount uint)
    (is-successful bool))
  (match (map-get? participants {participant: participant})
    profile
    (let (
      (new-total (+ (get total-transactions profile) u1))
      (new-successful (if is-successful (+ (get successful-transactions profile) u1) (get successful-transactions profile)))
      (success-rate (/ (* new-successful u100) new-total))
      (new-rating (+ u500 (/ success-rate u2)))
    )
      (map-set participants
        {participant: participant}
        (merge profile {
          total-transactions: new-total,
          successful-transactions: new-successful,
          total-financed: (+ (get total-financed profile) transaction-amount),
          credit-rating: new-rating,
          reputation-score: (if (<= new-rating u800) new-rating u800)
        })
      )
    )
    false
  )
)

;; Validate purchase order
(define-private (is-valid-order
    (amount uint)
    (delivery-date uint)
    (payment-terms uint))
  (and
    (> amount u0)
    (> delivery-date stacks-block-height)
    (>= payment-terms u1)
    (<= payment-terms u365)
  )
)

;; public functions
;; Register as a participant
(define-public (register-participant
    (name (string-ascii 128))
    (participant-type uint))
  (let (
    (participant tx-sender)
  )
    (asserts! (<= participant-type u3) ERR-INVALID-STATUS)
    (asserts! (is-none (map-get? participants {participant: participant})) ERR-ORDER-EXISTS)
    
    (map-set participants
      {participant: participant}
      {
        name: name,
        participant-type: participant-type,
        credit-rating: u650,
        total-transactions: u0,
        successful-transactions: u0,
        total-financed: u0,
        reputation-score: u50,
        verified: true, ;; Auto-verify for demo
        joined-at: stacks-block-height
      }
    )
    (ok true)
  )
)

;; Submit a purchase order
(define-public (submit-purchase-order
    (order-id (string-ascii 64))
    (buyer principal)
    (amount uint)
    (description (string-ascii 512))
    (delivery-date uint)
    (payment-terms uint)
    (verification-hash (string-ascii 128)))
  (let (
    (supplier tx-sender)
  )
    (asserts! (is-valid-order amount delivery-date payment-terms) ERR-INVALID-STATUS)
    (asserts! (is-none (map-get? purchase-orders {order-id: order-id})) ERR-ORDER-EXISTS)
    
    (map-set purchase-orders
      {order-id: order-id}
      {
        supplier: supplier,
        buyer: buyer,
        amount: amount,
        description: description,
        delivery-date: delivery-date,
        payment-terms: payment-terms,
        verification-hash: verification-hash,
        status: ORDER-SUBMITTED,
        created-at: stacks-block-height,
        verified-at: none,
        delivered-at: none,
        paid-at: none
      }
    )
    
    (var-set next-order-id (+ (var-get next-order-id) u1))
    (var-set total-orders (+ (var-get total-orders) u1))
    (ok order-id)
  )
)

;; Verify purchase order (by buyer or authorized verifier)
(define-public (verify-purchase-order (order-id (string-ascii 64)))
  (let (
    (verifier tx-sender)
  )
    (match (map-get? purchase-orders {order-id: order-id})
      order
      (begin
        (asserts! (or (is-eq verifier (get buyer order)) (is-eq verifier CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status order) ORDER-SUBMITTED) ERR-INVALID-STATUS)
        
        (map-set purchase-orders
          {order-id: order-id}
          (merge order {
            status: ORDER-VERIFIED,
            verified-at: (some stacks-block-height)
          })
        )
        (ok true)
      )
      ERR-ORDER-NOT-FOUND
    )
  )
)

;; Provide financing for verified purchase order
(define-public (provide-financing
    (agreement-id (string-ascii 64))
    (order-id (string-ascii 64))
    (custom-interest-rate (optional uint)))
  (let (
    (financier tx-sender)
  )
    (match (map-get? purchase-orders {order-id: order-id})
      order
      (let (
        (financing-terms (calculate-financing-terms 
          (get amount order) 
          (get supplier order) 
          (get buyer order) 
          (get payment-terms order)))
        (final-rate (match custom-interest-rate
          rate rate
          (get interest-rate financing-terms)))
        (principal-amount (get principal-amount financing-terms))
        (platform-fee (/ (* principal-amount (var-get platform-fee-rate)) u10000))
        (supplier-payment (- principal-amount platform-fee))
      )
        (asserts! (is-eq (get status order) ORDER-VERIFIED) ERR-NOT-VERIFIED)
        (asserts! (>= (stx-get-balance financier) principal-amount) ERR-INSUFFICIENT-FUNDS)
        (asserts! (is-none (map-get? financing-agreements {agreement-id: agreement-id})) ERR-FINANCING-EXISTS)
        
        ;; Transfer funds
        (try! (stx-transfer? supplier-payment financier (get supplier order)))
        (try! (stx-transfer? platform-fee financier CONTRACT-OWNER))
        
        ;; Create financing agreement
        (map-set financing-agreements
          {agreement-id: agreement-id}
          {
            order-id: order-id,
            financier: financier,
            supplier: (get supplier order),
            principal-amount: principal-amount,
            interest-rate: final-rate,
            term-days: (get payment-terms order),
            advance-rate: (get advance-rate financing-terms),
            total-repayment: (get total-repayment financing-terms),
            amount-repaid: u0,
            status: FINANCING-ACTIVE,
            funded-at: stacks-block-height,
            due-date: (+ stacks-block-height (* (get payment-terms order) u144)), ;; Approximate
            collateral-value: (get amount order)
          }
        )
        
        ;; Update order status
        (map-set purchase-orders
          {order-id: order-id}
          (merge order {status: ORDER-FINANCED})
        )
        
        ;; Update statistics
        (var-set next-agreement-id (+ (var-get next-agreement-id) u1))
        (var-set total-financed-amount (+ (var-get total-financed-amount) principal-amount))
        
        ;; Update participant stats
        (update-participant-stats (get supplier order) principal-amount true)
        (update-participant-stats financier principal-amount true)
        
        (ok agreement-id)
      )
      ERR-ORDER-NOT-FOUND
    )
  )
)

;; Confirm delivery (by buyer)
(define-public (confirm-delivery (order-id (string-ascii 64)))
  (let (
    (confirmer tx-sender)
  )
    (match (map-get? purchase-orders {order-id: order-id})
      order
      (begin
        (asserts! (is-eq confirmer (get buyer order)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status order) ORDER-FINANCED) ERR-INVALID-STATUS)
        
        (map-set purchase-orders
          {order-id: order-id}
          (merge order {
            status: ORDER-DELIVERED,
            delivered-at: (some stacks-block-height)
          })
        )
        (ok true)
      )
      ERR-ORDER-NOT-FOUND
    )
  )
)

;; Make payment (by buyer to financier)
(define-public (make-repayment
    (agreement-id (string-ascii 64))
    (payment-amount uint))
  (let (
    (payer tx-sender)
  )
    (match (map-get? financing-agreements {agreement-id: agreement-id})
      agreement
      (match (map-get? purchase-orders {order-id: (get order-id agreement)})
        order
        (let (
          (is-buyer (is-eq payer (get buyer order)))
          (remaining-balance (- (get total-repayment agreement) (get amount-repaid agreement)))
          (payment (if (> payment-amount remaining-balance) remaining-balance payment-amount))
          (new-amount-repaid (+ (get amount-repaid agreement) payment))
          (is-fully-paid (>= new-amount-repaid (get total-repayment agreement)))
        )
          (asserts! is-buyer ERR-NOT-AUTHORIZED)
          (asserts! (is-eq (get status agreement) FINANCING-ACTIVE) ERR-INVALID-STATUS)
          (asserts! (>= (stx-get-balance payer) payment) ERR-INSUFFICIENT-FUNDS)
          
          ;; Transfer payment to financier
          (try! (stx-transfer? payment payer (get financier agreement)))
          
          ;; Update financing agreement
          (map-set financing-agreements
            {agreement-id: agreement-id}
            (merge agreement {
              amount-repaid: new-amount-repaid,
              status: (if is-fully-paid FINANCING-REPAID FINANCING-ACTIVE)
            })
          )
          
          ;; Update order status if fully paid
          (if is-fully-paid
              (map-set purchase-orders
                {order-id: (get order-id agreement)}
                (merge order {
                  status: ORDER-PAID,
                  paid-at: (some stacks-block-height)
                })
              )
              true
          )
          
          ;; Update statistics
          (var-set total-repaid-amount (+ (var-get total-repaid-amount) payment))
          
          ;; Update participant stats
          (update-participant-stats payer payment true)
          
          (ok payment)
        )
        ERR-ORDER-NOT-FOUND
      )
      ERR-ORDER-NOT-FOUND
    )
  )
)

;; Get purchase order information
(define-public (get-purchase-order (order-id (string-ascii 64)))
  (ok (map-get? purchase-orders {order-id: order-id}))
)

;; Get financing agreement information
(define-public (get-financing-agreement (agreement-id (string-ascii 64)))
  (ok (map-get? financing-agreements {agreement-id: agreement-id}))
)

;; Get participant information
(define-public (get-participant-info (participant principal))
  (ok (map-get? participants {participant: participant}))
)

;; read only functions
;; Get platform statistics
(define-read-only (get-platform-stats)
  {
    total-orders: (var-get total-orders),
    total-financed-amount: (var-get total-financed-amount),
    total-repaid-amount: (var-get total-repaid-amount),
    platform-fee-rate: (var-get platform-fee-rate)
  }
)

;; Calculate financing quote
(define-read-only (get-financing-quote
    (order-amount uint)
    (supplier principal)
    (buyer principal)
    (term-days uint))
  (calculate-financing-terms order-amount supplier buyer term-days)
)

;; Check order eligibility for financing
(define-read-only (is-order-eligible (order-id (string-ascii 64)))
  (match (map-get? purchase-orders {order-id: order-id})
    order (is-eq (get status order) ORDER-VERIFIED)
    false
  )
)

;; Get participant credit rating
(define-read-only (get-credit-rating (participant principal))
  (get-participant-credit-rating participant)
)
