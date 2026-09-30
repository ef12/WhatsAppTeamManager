package nl.rkavic.manager

import android.annotation.SuppressLint
import android.app.*
import android.os.Bundle
import android.content.*
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.graphics.Color
import android.text.InputType
import android.widget.*
import java.text.SimpleDateFormat
import java.util.*

class MainActivity : Activity() {
    private lateinit var db: Store
    private lateinit var root: LinearLayout
    private val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault())
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); db = Store(this); showHome() }
    private fun screen(title: String) {
        val outer = ScrollView(this); root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(24,24,24,24) }
        outer.addView(root); setContentView(outer)
        label(title, 24f)
    }
    private fun label(s: String, size: Float = 17f) { root.addView(TextView(this).apply { text=s; textSize=size; setTextColor(Color.BLACK); setPadding(4,12,4,12) }) }
    private fun button(s: String, f: () -> Unit) { root.addView(Button(this).apply { text=s; setOnClickListener { f() } }) }
    private fun input(hint: String): EditText = EditText(this).also { it.hint=hint; root.addView(it) }
    private fun toast(s: String) = Toast.makeText(this,s,Toast.LENGTH_LONG).show()
    private fun ask(title: String, options: Array<String>, f: (Int)->Unit) { AlertDialog.Builder(this).setTitle(title).setItems(options) { _, i -> f(i) }.show() }
    private fun share(s: String) { startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type="text/plain"; putExtra(Intent.EXTRA_TEXT,s) }, "Send to WhatsApp group")) }
    private fun showHome() {
        screen("⚽ Team Manager")
        label("Offline team organizer · WhatsApp message drafts")
        button("Players and parents") { showPlayers() }
        button("Matches") { showMatches() }
        button("Add match") { addMatch() }
        val matches = db.matches(); val next = matches.firstOrNull { !it.done }
        label(if(next==null) "No open matches" else "Next open match: ${next.title} · ${next.date}")
    }
    private fun showPlayers() {
        screen("Players and parents"); button("← Home") { showHome() }
        val name=input("Player name"); val parent=input("Parent name (optional)")
        button("Add player") { if(name.text.isBlank()) toast("Enter a player name") else { db.addPlayer(name.text.toString().trim(),parent.text.toString().trim()); showPlayers() } }
        db.players().forEach { p -> button("${p.name} · ${p.parent.ifBlank { "parent unknown" }}") {
            ask(p.name, arrayOf("Edit", "Delete")) { n -> if(n==0) editPlayer(p) else AlertDialog.Builder(this).setMessage("Delete ${p.name} and their attendance and duties?").setPositiveButton("Delete") { _,_ -> db.deletePlayer(p.id); showPlayers() }.setNegativeButton("Cancel",null).show() }
        } }
    }
    private fun editPlayer(p: Player) { screen("Edit player"); val n=input("Player name").apply { setText(p.name) }; val a=input("Parent name").apply { setText(p.parent) }; button("Save") { if(n.text.isBlank()) toast("Enter a player name") else { db.updatePlayer(p.id,n.text.toString().trim(),a.text.toString().trim()); showPlayers() } }; button("Cancel") { showPlayers() } }
    private fun showMatches() { screen("Matches"); button("← Home") { showHome() }; button("Add match") { addMatch() }; db.matches().forEach { m -> button("${m.date} · ${m.title}${if(m.done) " · Done" else ""}") { showMatch(m.id) } } }
    private fun addMatch() {
        screen("Add match"); label("Date and times use YYYY-MM-DD HH:MM. Example: 2026-10-03 08:30")
        val title=input("Opponent / match title"); val date=input("Kickoff: YYYY-MM-DD HH:MM"); val meet=input("Meetup: YYYY-MM-DD HH:MM"); val location=input("Location"); val deadline=input("Attendance deadline: YYYY-MM-DD HH:MM")
        button("Save match") {
            val values=listOf(date,meet,deadline).map { it.text.toString().trim() }
            if(title.text.isBlank() || values.any { parse(it)==null }) toast("Enter a title and valid dates")
            else { db.addMatch(title.text.toString().trim(),values[0],values[1],location.text.toString().trim(),values[2]); showMatches() }
        }; button("Cancel") { showMatches() }
    }
    private fun editMatch(m: Match) {
        screen("Edit match"); label("Date and times use YYYY-MM-DD HH:MM. Example: 2026-10-03 08:30")
        val title=input("Opponent / match title").apply { setText(m.title) }
        val date=input("Kickoff: YYYY-MM-DD HH:MM").apply { setText(m.date) }
        val meet=input("Meetup: YYYY-MM-DD HH:MM").apply { setText(m.meet) }
        val location=input("Location").apply { setText(m.location) }
        val deadline=input("Attendance deadline: YYYY-MM-DD HH:MM").apply { setText(m.deadline) }
        button("Save changes") {
            val values=listOf(date,meet,deadline).map { it.text.toString().trim() }
            if(title.text.isBlank() || values.any { parse(it)==null }) toast("Enter a title and valid dates")
            else { db.updateMatch(m.id,title.text.toString().trim(),values[0],values[1],location.text.toString().trim(),values[2]); showMatch(m.id) }
        }
        button("Cancel") { showMatch(m.id) }
    }
    @SuppressLint("SetTextI18n")
    private fun editResult(m: Match) {
        screen("Result and status"); label(m.title)
        val rkavic=input("RKAVIC goals").apply { inputType=InputType.TYPE_CLASS_NUMBER; setText(m.rkavicScore?.toString() ?: "") }
        val opponent=input("Opponent goals").apply { inputType=InputType.TYPE_CLASS_NUMBER; setText(m.opponentScore?.toString() ?: "") }
        val done=CheckBox(this).apply { text="Match done"; isChecked=m.done }
        root.addView(done)
        label("Leave both scores empty if there is no result yet.")
        button("Save result and status") {
            val first=rkavic.text.toString().trim(); val second=opponent.text.toString().trim()
            val bothEmpty=first.isEmpty() && second.isEmpty()
            val firstScore=first.toIntOrNull(); val secondScore=second.toIntOrNull()
            if(!bothEmpty && (firstScore==null || secondScore==null || firstScore<0 || secondScore<0)) toast("Enter both scores as non-negative whole numbers")
            else { db.setMatchResult(m.id,firstScore,secondScore,done.isChecked); showMatch(m.id) }
        }
        button("Cancel") { showMatch(m.id) }
    }
    private fun parse(s: String): Date? = try { fmt.isLenient=false; fmt.parse(s)?.takeIf { fmt.format(it)==s } } catch(_: Exception) { null }
    private fun showMatch(id: Long) {
        val m=db.match(id) ?: return showMatches(); screen("⚽ ${m.title}"); button("← Matches") { showMatches() }
        label("Kickoff: ${m.date}\nMeet: ${m.meet}\nLocation: ${m.location}\nReply by: ${m.deadline}")
        label("Status: ${if(m.done) "Done" else "Not done"}\nResult: ${if(m.rkavicScore!=null && m.opponentScore!=null) "RKAVIC ${m.rkavicScore} - ${m.opponentScore} Opponent" else "Not entered"}")
        button("Edit match") { editMatch(m) }
        button("Result and status") { editResult(m) }
        val players=db.players(); val statuses=db.attendance(id); val coming=players.count { statuses[it.id]==1 }; val absent=players.count { statuses[it.id]==2 }
        label("✅ $coming coming   ❌ $absent absent   ❓ ${players.size-coming-absent} unanswered")
        players.forEach { p -> button("${when(statuses[p.id]) { 1->"✅"; 2->"❌"; else->"❓" }} ${p.name}") { ask("${p.name} attending?", arrayOf("Coming", "Not coming", "No response")) { v -> db.setAttendance(id,p.id,if(v==2) 0 else v+1); showMatch(id) } } }
        label("Match duties",21f)
        val task=input("Duty (e.g. field setup)")
        button("Add duty") { if(task.text.isNotBlank()) { db.addDuty(id,task.text.toString().trim()); showMatch(id) } }
        db.duties(id).forEach { duty ->
            val who=players.firstOrNull { it.id==duty.playerId }?.parent?.ifBlank { null } ?: players.firstOrNull { it.id==duty.playerId }?.name ?: "Unassigned"
            button("${duty.title} · $who · ${if(duty.done) "Completed" else "Pending"}") {
                val names=arrayOf("Unassigned")+players.map { "${it.parent.ifBlank { it.name }} (${it.name})" }
                ask(duty.title, arrayOf("Assign parent/player", "Mark ${if(duty.done) "pending" else "completed"}", "Delete duty")) { action ->
                    when(action) { 0 -> ask("Assign to",names) { i -> db.assignDuty(duty.id,players.getOrNull(i-1)?.id); showMatch(id) }; 1 -> { db.completeDuty(duty.id,!duty.done); showMatch(id) }; 2 -> { db.deleteDuty(duty.id); showMatch(id) } }
                }
            }
        }
        label("WhatsApp drafts",21f)
        button("Match invitation") { share("⚽ ${m.title}\n📅 ${m.date}\n⏰ Meet: ${m.meet}\n📍 ${m.location}\nPlease confirm attendance by ${m.deadline}. 🙏") }
        button("Attendance reminder") { val missing=players.filter { statuses[it.id] == null || statuses[it.id]==0 }; share("⏰ Attendance reminder for ${m.title} (${m.date})\nStill waiting for: ${missing.joinToString(", ") { it.name }.ifBlank { "everyone has replied ✅" }}\nPlease reply by ${m.deadline}. 🙏") }
        button("Duty announcement") { val lines=db.duties(id).joinToString("\n") { d -> val p=players.firstOrNull { it.id==d.playerId }; "• ${d.title}: ${p?.parent?.ifBlank { p.name } ?: "volunteer needed"}" }; share("🟠 Match duties · ${m.title} (${m.date})\n$lines\nIf unavailable, please arrange a replacement and inform me.") }
        button("Request substitutes") { share("🚨 Substitute players needed for ${m.title}\n📅 ${m.date}\n⏰ Meet: ${m.meet}\n📍 ${m.location}\nWho can help? 🙏⚽") }
        button("Delete match") { AlertDialog.Builder(this).setMessage("Delete this match, attendance and duties?").setPositiveButton("Delete") { _,_ -> db.deleteMatch(id); showMatches() }.setNegativeButton("Cancel",null).show() }
    }
}

data class Player(val id:Long,val name:String,val parent:String)
data class Match(val id:Long,val title:String,val date:String,val meet:String,val location:String,val deadline:String,val rkavicScore:Int?,val opponentScore:Int?,val done:Boolean)
data class Duty(val id:Long,val title:String,val playerId:Long?,val done:Boolean)
class Store(ctx: Context): SQLiteOpenHelper(ctx,"team.db",null,2) {
    override fun onCreate(d:SQLiteDatabase) { d.execSQL("CREATE TABLE players(id INTEGER PRIMARY KEY,name TEXT NOT NULL,parent TEXT NOT NULL)"); d.execSQL("CREATE TABLE matches(id INTEGER PRIMARY KEY,title TEXT NOT NULL,date TEXT NOT NULL,meet TEXT NOT NULL,location TEXT NOT NULL,deadline TEXT NOT NULL,rkavic_score INTEGER,opponent_score INTEGER,done INTEGER NOT NULL DEFAULT 0)"); d.execSQL("CREATE TABLE attendance(match_id INTEGER NOT NULL,player_id INTEGER NOT NULL,status INTEGER NOT NULL,PRIMARY KEY(match_id,player_id))"); d.execSQL("CREATE TABLE duties(id INTEGER PRIMARY KEY,match_id INTEGER NOT NULL,title TEXT NOT NULL,player_id INTEGER,done INTEGER NOT NULL DEFAULT 0)") }
    override fun onUpgrade(d:SQLiteDatabase,old:Int,new:Int) { if(old<2) { d.execSQL("ALTER TABLE matches ADD COLUMN rkavic_score INTEGER"); d.execSQL("ALTER TABLE matches ADD COLUMN opponent_score INTEGER"); d.execSQL("ALTER TABLE matches ADD COLUMN done INTEGER NOT NULL DEFAULT 0") } }
    private fun values(vararg pairs: Pair<String,Any?>) = ContentValues().apply { pairs.forEach { (k,v) -> when(v) { null -> putNull(k); is String -> put(k,v); is Long -> put(k,v); is Int -> put(k,v) } } }
    fun addPlayer(n:String,p:String) { writableDatabase.insert("players",null,values("name" to n,"parent" to p)) }
    fun updatePlayer(id:Long,n:String,p:String) { writableDatabase.update("players",values("name" to n,"parent" to p),"id=?",arrayOf("$id")) }
    fun deletePlayer(id:Long) { writableDatabase.delete("players","id=?",arrayOf("$id")); writableDatabase.delete("attendance","player_id=?",arrayOf("$id")); writableDatabase.execSQL("UPDATE duties SET player_id=NULL WHERE player_id=?",arrayOf(id)) }
    fun players():List<Player> = mutableListOf<Player>().also { out -> readableDatabase.rawQuery("SELECT id,name,parent FROM players ORDER BY name",null).use { c -> while(c.moveToNext()) out.add(Player(c.getLong(0),c.getString(1),c.getString(2))) } }
    fun addMatch(t:String,d:String,m:String,l:String,deadline:String) { writableDatabase.insert("matches",null,values("title" to t,"date" to d,"meet" to m,"location" to l,"deadline" to deadline)) }
    fun updateMatch(id:Long,t:String,d:String,m:String,l:String,deadline:String) { writableDatabase.update("matches",values("title" to t,"date" to d,"meet" to m,"location" to l,"deadline" to deadline),"id=?",arrayOf("$id")) }
    fun setMatchResult(id:Long,rkavicScore:Int?,opponentScore:Int?,done:Boolean) { writableDatabase.update("matches",values("rkavic_score" to rkavicScore,"opponent_score" to opponentScore,"done" to if(done) 1 else 0),"id=?",arrayOf("$id")) }
    fun matches():List<Match> = mutableListOf<Match>().also { out -> readableDatabase.rawQuery("SELECT id,title,date,meet,location,deadline,rkavic_score,opponent_score,done FROM matches ORDER BY date",null).use { c -> while(c.moveToNext()) out.add(Match(c.getLong(0),c.getString(1),c.getString(2),c.getString(3),c.getString(4),c.getString(5),if(c.isNull(6)) null else c.getInt(6),if(c.isNull(7)) null else c.getInt(7),c.getInt(8)!=0)) } }
    fun match(id:Long):Match? = matches().firstOrNull { it.id==id }
    fun deleteMatch(id:Long) { writableDatabase.delete("matches","id=?",arrayOf("$id")); writableDatabase.delete("attendance","match_id=?",arrayOf("$id")); writableDatabase.delete("duties","match_id=?",arrayOf("$id")) }
    fun attendance(id:Long):Map<Long,Int> = mutableMapOf<Long,Int>().also { out -> readableDatabase.rawQuery("SELECT player_id,status FROM attendance WHERE match_id=?",arrayOf("$id")).use { c -> while(c.moveToNext()) out[c.getLong(0)]=c.getInt(1) } }
    fun setAttendance(m:Long,p:Long,s:Int) { writableDatabase.insertWithOnConflict("attendance",null,values("match_id" to m,"player_id" to p,"status" to s),SQLiteDatabase.CONFLICT_REPLACE) }
    fun addDuty(m:Long,t:String) { writableDatabase.insert("duties",null,values("match_id" to m,"title" to t,"done" to 0)) }
    fun duties(m:Long):List<Duty> = mutableListOf<Duty>().also { out -> readableDatabase.rawQuery("SELECT id,title,player_id,done FROM duties WHERE match_id=? ORDER BY id",arrayOf("$m")).use { c -> while(c.moveToNext()) out.add(Duty(c.getLong(0),c.getString(1),if(c.isNull(2)) null else c.getLong(2),c.getInt(3)!=0)) } }
    fun assignDuty(id:Long,p:Long?) { writableDatabase.update("duties",values("player_id" to p),"id=?",arrayOf("$id")) }
    fun completeDuty(id:Long,b:Boolean) { writableDatabase.update("duties",values("done" to if(b) 1 else 0),"id=?",arrayOf("$id")) }
    fun deleteDuty(id:Long) { writableDatabase.delete("duties","id=?",arrayOf("$id")) }
}
