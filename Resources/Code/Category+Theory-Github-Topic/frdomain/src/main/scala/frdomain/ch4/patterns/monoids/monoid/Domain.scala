package frdomain.ch4
package patterns
package monoids.monoid

import java.util.Date

sealed trait TransactionType
case object DR extends TransactionType
case object CR extends TransactionType

sealed trait Currency
case object USD extends Currency
case object JPY extends Currency
case object AUD extends Currency
case object INR extends Currency

object common {
  type Amount = BigDecimal
}

import common._

case class Money(m: Map[Currency, Amount]) {
  def toBaseCurrency: Amount = ???
}

trait Analytics[Transaction, Balance, Money] {
  def maxDebitOnDay(txns: List[Transaction])(implicit m: Monoid[Money]): Money
  def sumBalances(bs: List[Balance])(implicit m: Monoid[Money]): Money
}

case class Transaction(txid: String, accountNo: String, date: Date, amount: Money, txnType: TransactionType, status: Boolean)

case class Balance(b: Money)

object Analytics extends Analytics[Transaction, Balance, Money] {
  import Monoid._

  final val baseCurrency = USD

  private def valueOf(txn: Transaction): Money = {
    if (txn.status) txn.amount
    else MoneyAdditionMonoid.op(txn.amount, Money(Map(baseCurrency -> BigDecimal(100))))
  }

  private def creditBalance(bal: Balance): Money = {
    if (bal.b.toBaseCurrency > 0) bal.b else zeroMoney
  }

  def maxDebitOnDay(txns: List[Transaction])(implicit m: Monoid[Money]): Money = {
    txns.filter(_.txnType == DR).foldLeft(m.zero) { (a, txn) => m.op(a, valueOf(txn)) }
  }

  def sumBalances(bs: List[Balance])(implicit m: Monoid[Money]): Money = 
    bs.foldLeft(m.zero) { (a, bal) => m.op(a, creditBalance(bal)) }
}
