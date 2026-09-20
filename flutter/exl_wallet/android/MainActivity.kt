package com.excobalab.zipla

import android.net.Uri
import android.os.Bundle
import com.solana.mobilewalletadapter.clientlib.*
import com.solana.publickey.SolanaPublicKey
import com.solana.transaction.AccountMeta
import com.solana.transaction.Message
import com.solana.transaction.Transaction
import com.solana.transaction.TransactionInstruction
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * EXCOBALAB — MWA 2.0 native köprüsü (Zipla Ex).
 * "payPremium" genel amaçlı transfer+memo imzalatır (turnuva girişleri dahil).
 */
class MainActivity : FlutterFragmentActivity() {
    private lateinit var resultSender: ActivityResultSender
    private val mainScope = CoroutineScope(Dispatchers.Main)

    private val walletAdapter: MobileWalletAdapter by lazy {
        MobileWalletAdapter(
            connectionIdentity = ConnectionIdentity(
                identityUri = Uri.parse("https://excobalab.com"),
                iconUri = Uri.parse("favicon.ico"),
                identityName = "Zipla Ex",
            )
        ).apply { blockchain = Solana.Mainnet }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        resultSender = ActivityResultSender(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "exl/mwa")
            .setMethodCallHandler { call, methodResult ->
                when (call.method) {
                    "payPremium" -> {
                        val recipient = call.argument<String>("recipient")
                        val lamports = call.argument<Number>("lamports")?.toLong()
                        val memoText = call.argument<String>("memo")
                        val blockhash = call.argument<String>("blockhash")
                        if (recipient == null || lamports == null ||
                            memoText == null || blockhash == null
                        ) {
                            methodResult.error("ARG", "missing arguments", null)
                            return@setMethodCallHandler
                        }
                        mainScope.launch {
                            try {
                                walletAdapter.authToken = null
                                val result = walletAdapter.transact(resultSender) { authResult ->
                                    val payer =
                                        SolanaPublicKey(authResult.accounts.first().publicKey)
                                    val to = SolanaPublicKey.from(recipient)
                                    val transferData = ByteBuffer.allocate(12)
                                        .order(ByteOrder.LITTLE_ENDIAN)
                                        .putInt(2)
                                        .putLong(lamports)
                                        .array()
                                    val transferIx = TransactionInstruction(
                                        SolanaPublicKey.from("11111111111111111111111111111111"),
                                        listOf(
                                            AccountMeta(payer, true, true),
                                            AccountMeta(to, false, true),
                                        ),
                                        transferData
                                    )
                                    val memoIx = TransactionInstruction(
                                        SolanaPublicKey.from("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"),
                                        listOf(AccountMeta(payer, true, true)),
                                        memoText.encodeToByteArray()
                                    )
                                    val txMessage = Message.Builder()
                                        .addInstruction(transferIx)
                                        .addInstruction(memoIx)
                                        .setRecentBlockhash(blockhash)
                                        .build()
                                    signAndSendTransactions(
                                        arrayOf(Transaction(txMessage).serialize())
                                    )
                                }
                                when (result) {
                                    is TransactionResult.Success -> {
                                        val sig =
                                            result.successPayload?.signatures?.firstOrNull()
                                        if (sig != null) methodResult.success(sig)
                                        else methodResult.error("EMPTY", "Wallet returned no signature", null)
                                    }
                                    is TransactionResult.NoWalletFound ->
                                        methodResult.error("NOWALLET",
                                            "No compatible Solana wallet found on this device", null)
                                    is TransactionResult.Failure ->
                                        methodResult.error("FAIL",
                                            result.e.message ?: "Payment was not approved", null)
                                }
                            } catch (e: Exception) {
                                methodResult.error("EX", e.message ?: "Unexpected error", null)
                            }
                        }
                    }
                    else -> methodResult.notImplemented()
                }
            }
    }
}
