package com.excobalab.zipla

import android.net.Uri
import android.os.Bundle
import com.solana.mobilewalletadapter.clientlib.*
import com.solana.publickey.ProgramDerivedAddress
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
 * EXCOBALAB — MWA 2.0 native bridge (EXL Tourney v1.1).
 *
 *  "payPremium"  transfer + memo, signed and sent by the wallet.
 *                SOL:  { recipient, lamports, memo, blockhash }
 *                SPL:  { recipient, lamports (base units), memo, blockhash,
 *                        mint, decimals, destTokenAccount }   ← SKR tournaments
 *                Returns the tx signature bytes.
 *  "signScore"   { message } → detached ed25519 signature of the UTF-8 message by the
 *                authorized account (Seed Vault on Seeker). Returns { signature, wallet } as base58.
 */
class MainActivity : FlutterFragmentActivity() {
    private lateinit var resultSender: ActivityResultSender
    private val mainScope = CoroutineScope(Dispatchers.Main)

    private val systemProgram = SolanaPublicKey.from("11111111111111111111111111111111")
    private val memoProgram = SolanaPublicKey.from("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr")
    private val tokenProgram = SolanaPublicKey.from("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
    private val ataProgram = SolanaPublicKey.from("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")

    private val walletAdapter: MobileWalletAdapter by lazy {
        MobileWalletAdapter(
            connectionIdentity = ConnectionIdentity(
                identityUri = Uri.parse("https://excobalab.com"),
                iconUri = Uri.parse("favicon.ico"),
                identityName = "Sol Jump",
            )
        ).apply { blockchain = Solana.Mainnet }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        resultSender = ActivityResultSender(this)
    }

    private val base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    private fun base58(bytes: ByteArray): String {
        var zeros = 0
        while (zeros < bytes.size && bytes[zeros].toInt() == 0) zeros++
        var num = java.math.BigInteger(1, bytes)
        val sb = StringBuilder()
        val base = java.math.BigInteger.valueOf(58)
        while (num > java.math.BigInteger.ZERO) {
            val divRem = num.divideAndRemainder(base)
            sb.append(base58Alphabet[divRem[1].toInt()])
            num = divRem[0]
        }
        repeat(zeros) { sb.append('1') }
        return sb.reverse().toString()
    }

    private suspend fun associatedTokenAddress(owner: SolanaPublicKey, mint: SolanaPublicKey): SolanaPublicKey {
        val pda = ProgramDerivedAddress.find(
            listOf(owner.bytes, tokenProgram.bytes, mint.bytes), ataProgram
        ).getOrThrow()
        return SolanaPublicKey(pda.bytes)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "exl/mwa")
            .setMethodCallHandler { call, methodResult ->
                when (call.method) {
                    "payPremium" -> {
                        val recipient = call.argument<String>("recipient")
                        val amount = call.argument<Number>("lamports")?.toLong()
                        val memoText = call.argument<String>("memo")
                        val blockhash = call.argument<String>("blockhash")
                        val mint = call.argument<String>("mint")                 // null = SOL transfer
                        val decimals = call.argument<Number>("decimals")?.toInt() ?: 0
                        val destTokenAccount = call.argument<String>("destTokenAccount")
                        if (recipient == null || amount == null || memoText == null || blockhash == null ||
                            (mint != null && destTokenAccount == null)
                        ) {
                            methodResult.error("ARG", "missing arguments", null)
                            return@setMethodCallHandler
                        }
                        mainScope.launch {
                            try {
                                walletAdapter.authToken = null
                                val result = walletAdapter.transact(resultSender) { authResult ->
                                    val payer = SolanaPublicKey(authResult.accounts.first().publicKey)
                                    val transferIx: TransactionInstruction = if (mint == null) {
                                        // System transfer (SOL)
                                        val data = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN)
                                            .putInt(2).putLong(amount).array()
                                        TransactionInstruction(
                                            systemProgram,
                                            listOf(
                                                AccountMeta(payer, true, true),
                                                AccountMeta(SolanaPublicKey.from(recipient), false, true),
                                            ),
                                            data
                                        )
                                    } else {
                                        // SPL TransferChecked: [12, amount u64 LE, decimals u8]
                                        val mintKey = SolanaPublicKey.from(mint)
                                        val sourceAta = associatedTokenAddress(payer, mintKey)
                                        val destAta = SolanaPublicKey.from(destTokenAccount!!)
                                        val data = ByteBuffer.allocate(10).order(ByteOrder.LITTLE_ENDIAN)
                                            .put(12.toByte()).putLong(amount).put(decimals.toByte()).array()
                                        TransactionInstruction(
                                            tokenProgram,
                                            listOf(
                                                AccountMeta(sourceAta, false, true),
                                                AccountMeta(mintKey, false, false),
                                                AccountMeta(destAta, false, true),
                                                AccountMeta(payer, true, false),
                                            ),
                                            data
                                        )
                                    }
                                    val memoIx = TransactionInstruction(
                                        memoProgram,
                                        listOf(AccountMeta(payer, true, true)),
                                        memoText.encodeToByteArray()
                                    )
                                    val txMessage = Message.Builder()
                                        .addInstruction(transferIx)
                                        .addInstruction(memoIx)
                                        .setRecentBlockhash(blockhash)
                                        .build()
                                    signAndSendTransactions(arrayOf(Transaction(txMessage).serialize()))
                                }
                                when (result) {
                                    is TransactionResult.Success -> {
                                        val sig = result.successPayload?.signatures?.firstOrNull()
                                        if (sig != null) methodResult.success(sig)
                                        else methodResult.error("EMPTY", "Wallet returned no signature", null)
                                    }
                                    is TransactionResult.NoWalletFound ->
                                        methodResult.error("NOWALLET", "No compatible Solana wallet found on this device", null)
                                    is TransactionResult.Failure ->
                                        methodResult.error("FAIL", result.e.message ?: "Payment was not approved", null)
                                }
                            } catch (e: Exception) {
                                methodResult.error("EX", e.message ?: "Unexpected error", null)
                            }
                        }
                    }

                    "signScore" -> {
                        val message = call.argument<String>("message")
                        if (message == null) {
                            methodResult.error("ARG", "missing message", null)
                            return@setMethodCallHandler
                        }
                        mainScope.launch {
                            try {
                                walletAdapter.authToken = null
                                var walletB58 = ""
                                val result = walletAdapter.transact(resultSender) { authResult ->
                                    val account = authResult.accounts.first().publicKey
                                    walletB58 = base58(account)
                                    signMessagesDetached(arrayOf(message.encodeToByteArray()), arrayOf(account))
                                }
                                when (result) {
                                    is TransactionResult.Success -> {
                                        val sigBytes = result.successPayload?.messages?.firstOrNull()?.signatures?.firstOrNull()
                                        if (sigBytes != null) {
                                            methodResult.success(mapOf("signature" to base58(sigBytes), "wallet" to walletB58))
                                        } else methodResult.error("EMPTY", "Wallet returned no signature", null)
                                    }
                                    is TransactionResult.NoWalletFound ->
                                        methodResult.error("NOWALLET", "No compatible Solana wallet found on this device", null)
                                    is TransactionResult.Failure ->
                                        methodResult.error("FAIL", result.e.message ?: "Signing was not approved", null)
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
