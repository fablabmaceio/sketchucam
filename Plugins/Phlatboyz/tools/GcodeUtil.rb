require 'sketchup.rb'
require 'Phlatboyz/Constants.rb'

require 'Phlatboyz/PhlatboyzMethods.rb'
require 'Phlatboyz/PhlatOffset.rb'

require 'Phlatboyz/PhlatMill.rb'
require 'Phlatboyz/PhlatTool.rb'
require 'Phlatboyz/PhlatCut.rb'
require 'Phlatboyz/PSUpgrade.rb'
require 'Phlatboyz/Phlat3D.rb'
require 'Phlatboyz/PhlatProgress.rb'

module PhlatScript
  
  class GroupList < PhlatTool
    # this tool gets the list of groups containing phlatcuts and displays them in the cut order
    # it displays 2 levels deep in the case of a group of groups
    def initialize
       @tooltype=(PB_MENU_MENU)
       @tooltip="Group Listing in cut order"
       @statusText="Groups Summary display"
       @menuItem="Groups Summary"
       @menuText="Groups Summary"
    end
    
    # recursive method to add all group names to msg
    def listgroups(msg, ent, ii, depth)
      ent.each { |bit|
         if (bit.kind_of?(Sketchup::Group))
            bname = (bit.name.empty?) ? 'no name' : bit.name
            spacer = "   " * depth
            msg += spacer + ii.to_s + " - " + bname + "\n"
            msg = listgroups(msg,bit.entities,ii,depth+1)
         end
         }	
      return msg
    end

    def select
      groups = GroupList.listgroups()
      msg = "Summary of groups in CUT ORDER\n"
      if (groups.length > 0)
         i = 1
         groups.each { |e|
            ename = (e.name.empty?) ? 'no name' : e.name
            if (!ename.include?("safearea") )
               msg += i.to_s + " - " + ename + "\n"
               msg = listgroups(msg,e.entities,i,1)       # list all the groups that are members of this group
               i += 1
            end
            } #groups.each
      else
         msg += "No groups found to cut\n"
      end 
      UI.messagebox(msg,MB_MULTILINE)
    end #select
    
    # copied from loopnodefromentities so if that changes maybe this should too   
    def GroupList.listgroups
      #copied from "loopnodefromentities" and trimmed to just return the list of groups
      model = Sketchup.active_model
      entities = model.active_entities
      safe_area_points = P.get_safe_area_point3d_array()
      # find all outside loops
      loops = []
      groups = []
      phlatcuts = []
      dele_edges = [] # store edges that are part of loops to remove from phlatcuts
      entities.each { |e|
        if e.kind_of?(Sketchup::Face)
          has_edges = false
          # only keep loops that contain phlatcuts
          e.outer_loop.edges.each { |edge|
            pc = PhlatCut.from_edge(edge)
            has_edges = ((!pc.nil?) && (pc.in_polygon?(safe_area_points)))
            dele_edges.push(edge)
          }
          loops.push(e.outer_loop) if has_edges
        elsif e.kind_of?(Sketchup::Edge)
            # make sure that all edges are marked as not processed
            pc = PhlatCut.from_edge(e)
            if (pc)
              pc.processed = (false)
              phlatcuts.push(pc) if ((pc.in_polygon?(safe_area_points)) && ((pc.kind_of? PhlatScript::PlungeCut) || (pc.kind_of? PhlatScript::CenterLineCut)))
            end
        elsif e.kind_of?(Sketchup::Group)
          groups.push(e)
        end
        } # entities.each

      # make sure any edges part of a curve or loop aren't in the free standing phlatcuts array
      phlatcuts.collect! { |pc| dele_edges.include?(pc.edge) ? nil : pc }
      phlatcuts.compact!
      puts("Located #{groups.length.to_s} GROUPS containing PhlatCuts")   if (groups.length > 0)
      groups.each { |e|
        group_name = e.name
        puts "(Group: #{group_name})" if !group_name.empty?
        } #groups.each
      loops.flatten!
      loops.uniq!
      puts("Located #{loops.length.to_s} loops containing PhlatCuts")
      return groups
    end #listgroups
    
  end
#-%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

  class GcodeUtil < PhlatTool

    @@x_save = nil
    @@y_save = nil
    @@cut_depth_save = nil
    @g_save_point = Geom::Point3d.new(0, 0, 0) #swarfer: after a millEdges call, this will have the last point cut
    @optimize = true  #set to true to try find the closest point on the next group
    @current_bit_diameter = 0
    @tabletop = false  # is the Z0 on the table top?

    #swarfer: need these so that all aMill calls are given the right numbers, aMill should be unaware of defaults
    # by doing this we can have Z0 on the table surface, or at top of material
    if (@tabletop)
      @SafeHeight =  PhlatScript.materialThickness + PhlatScript.safeTravel.to_f
      @MaterialTop = PhlatScript.materialThickness
    else
      @SafeHeight = PhlatScript.safeTravel.to_f
      @MaterialTop = 0
    end

    def initialize
      @tooltype = 3
      @tooltip = PhlatScript.getString("Phlatboyz GCode")
      @largeIcon = "images/gcode_large.png"
      @smallIcon = "images/gcode_small.png"
      @statusText = PhlatScript.getString("Phlatboyz GCode")
      @menuItem = PhlatScript.getString("GCode")
      @menuText = PhlatScript.getString("GCode")
    end

    def select
      if PhlatScript.gen3D
	result = UI.messagebox 'Generate 3D GCode?', MB_OKCANCEL
	if result == 1  # OK
	  GCodeGen3D.new.generate
	  if PhlatScript.showGplot?
	    GPlot.new.plot
	  end
	else 
	  return 
	end
      else
	GcodeUtil.generate_gcode
	if PhlatScript.showGplot?
	  GPlot.new.plot
	end
      end
    end

    def statusText
      return "Generate Gcode output"
    end

    def GcodeUtil.generate_gcode
      if PSUpgrader.upgrade
        UI.messagebox("GCode generation has been aborted due to the upgrade")
        return
      end
      @g_save_point = Geom::Point3d.new(0, 0, 0)
      model = Sketchup.active_model
      if(enter_file_dialog(model))
        # first get the material thickness from the model dictionary
        material_thickness = Sketchup.active_model.get_attribute Dict_name, Dict_material_thickness, Default_material_thickness
        if(material_thickness)

          begin
            output_directory_name = model.get_attribute Dict_name, Dict_output_directory_name, Default_directory_name
            output_file_name = model.get_attribute Dict_name, Dict_output_file_name, Default_file_name
            @current_bit_diameter = model.get_attribute Dict_name, Dict_bit_diameter, Default_bit_diameter

            # TODO check for existing / on the end of output_directory_name
            absolute_File_name = output_directory_name + output_file_name

            safe_array = P.get_safe_array()
            min_x = 0.0
            min_y = 0.0
            max_x = safe_array[2]
            max_y = safe_array[3]
            safe_area_points = P.get_safe_area_point3d_array()

            min_max_array = [min_x, max_x, min_y, max_y, Min_z, Max_z]
            #aMill = CNCMill.new(nil, nil, absolute_File_name, min_max_array)
            aMill = PhlatMill.new(absolute_File_name, min_max_array)

            aMill.set_bit_diam(@current_bit_diameter)

#   puts("starting aMill absolute_File_name="+absolute_File_name)
            aMill.job_start(@optimize)
#   puts "amill jobstart done"
            loop_root = LoopNodeFromEntities(Sketchup.active_model.active_entities, aMill, material_thickness)
            loop_root.sort
            millLoopNode(aMill, loop_root, material_thickness)

            #puts("done milling")
            if PhlatScript.UseOutfeed?
               aMill.retract()
               aMill.cncPrint("(Outfeed)\n")
               aMill.move(PhlatScript.safeWidth * 0.75,0)
            else
               # retracts the milling head and and then moves it home.  
               # This prevents accidental milling
               # through your work piece when moving home.
               aMill.home()
            end   
            if (PhlatScript.useOverheadGantry?)
              if (Use_Home_Height != nil)
                if (Use_Home_Height)
                  aMill.retract(Default_Home_Height)
                end
              end
            end
            
            #puts("finishing up")
            aMill.job_finish() # output housekeeping code
          rescue
            UI.messagebox "GcodeUtil.generate_gcode failed; Error:"+$!
          end
        else
          UI.messagebox(PhlatScript.getString("You must define the material thickness."))
        end
      end
    end

    private

    def GcodeUtil.LoopNodeFromEntities(entities, aMill, material_thickness)
#      puts"loopnodefromentities"
      model = Sketchup.active_model
      safe_area_points = P.get_safe_area_point3d_array()
      # find all outside loops
      loops = []
      groups = []
      phlatcuts = []
      dele_edges = [] # store edges that are part of loops to remove from phlatcuts
      entities.each { |e|
        if e.kind_of?(Sketchup::Face)
          has_edges = false
          # only keep loops that contain phlatcuts
          e.outer_loop.edges.each { |edge|
            pc = PhlatCut.from_edge(edge)
            has_edges = ((!pc.nil?) && (pc.in_polygon?(safe_area_points)))
            dele_edges.push(edge)
          }
          loops.push(e.outer_loop) if has_edges
        elsif e.kind_of?(Sketchup::Edge)
            # make sure that all edges are marked as not processed
            pc = PhlatCut.from_edge(e)
            if (pc)
              pc.processed = (false)
              phlatcuts.push(pc) if ((pc.in_polygon?(safe_area_points)) && ((pc.kind_of? PhlatScript::PlungeCut) || (pc.kind_of? PhlatScript::CenterLineCut)))
            end
        elsif e.kind_of?(Sketchup::Group)
          groups.push(e)
        end
      }

      # make sure any edges part of a curve or loop aren't in the free standing phlatcuts array
      phlatcuts.collect! { |pc| dele_edges.include?(pc.edge) ? nil : pc }
      phlatcuts.compact!
      puts("Located #{groups.length.to_s} GROUPS containing PhlatCuts")   if (groups.length > 0)
      groups.each { |e|
        # this is a bit hacky and we should try to use a transformation based on
        # the group.local_bounds.corner(0) in the future
        group_name = e.name
        if (!group_name.empty?) # the safe area labels are groups with names containing 'safearea', dont print them
           aMill.cncPrint("(Group: #{group_name})\n")    if !group_name.include?("safearea") 
           puts "(Group: #{group_name})"                 if !group_name.include?("safearea") 
        end
        model.start_operation "Exploding Group", true
        es = e.explode
        gnode = LoopNodeFromEntities(es, aMill, material_thickness)
        gnode.sort
#		  puts "GNODE #{gnode}"
        millLoopNode(aMill, gnode, material_thickness)
        # abort the group explode
        model.abort_operation
        if (!group_name.empty?)
           aMill.cncPrint("(Group complete: #{group_name})\n")    if !group_name.include?("safearea") 
           puts "(Group end: #{group_name})"                      if !group_name.include?("safearea") 
        end
      }
      loops.flatten!
      loops.uniq!
      puts("Located #{loops.length.to_s} loops containing PhlatCuts")

      loop_root = LoopNode.new(nil)
      loops.each { |loop| loop_root.find_container(loop) }

      # push all the plunge, centerline and fold cuts into the proper loop node
      phlatcuts.each { |pc|
        loop_root.find_container(pc)
        pc.processed = true
      }
      return loop_root
    end

    def GcodeUtil.millLoopNode(aMill, loopNode, material_thickness)
      # always mill the child loops first
      loopNode.children.each{ |childloop|
        millLoopNode(aMill, childloop, material_thickness)
      }
#      if (PhlatScript.useMultipass?) and (Use_old_multipass == false)
#        loopNode.sorted_cuts.each { |sc| millEdges(aMill, [sc], material_thickness) }
#      else
#       millEdges(aMill, [sc], material_thickness)
#      end

    if (PhlatScript.useMultipass?) and (Use_old_multipass == false)   
      #all all the cuts the same type?
      first = true
      same = false
      atype = ""
      loopNode.sorted_cuts.each { |sc| 
#		   puts "sc #{sc}"
         if (first)
            atype = sc.class.to_s
            first = false
            same = true
         else
            if (atype != sc.class.to_s)
               same = false   
               break
           end
         end
         }
      if (same)  # all same type, if they are connected, cut together, else seperately
#			puts "SAME #{atype}"
         if (atype == "PhlatScript::CenterLineCut") || (atype == "PhlatScript::FoldCut")
            puts " same seperates?"
            cnt = 1
            fend = Geom::Point3d.new
            sstart = Geom::Point3d.new(1,1,1)
            # loop through the nodes and check if the end point of the first edge is the start point of the 2nd edge
            # if they are then cut together, else cut seperately
            loopNode.sorted_cuts.each { |pk|
               pk.cut_points(false) {    |cp, cut_factor|
                  if (cnt == 2)
                     fend = cp   
                  end
                  if (cnt == 3)
                     sstart = cp   
                  end
                  cnt = cnt + 1
                  }
               }
               
            if (fend.x == sstart.x	) && (fend.y == sstart.y)
               puts "   same Together #{atype}"
  				   millEdges(aMill, loopNode.sorted_cuts, material_thickness)
            else  # same separate
               loopNode.sorted_cuts.each { |sc| millEdges(aMill, [sc], material_thickness) }
            end
         else
            puts "  same together #{atype}"
            millEdges(aMill, loopNode.sorted_cuts, material_thickness)
         end
      else
   #   create arrays of same types, and cut them together
         folds = []
         centers = []
         others = []       #mostly plunge cuts
         loopNode.sorted_cuts.each { |sc| 
            cls = sc.class
            case cls.to_s
               when "PhlatScript::FoldCut"
                  folds.push(sc)
               when "PhlatScript::CenterLineCut"
                  centers.push(sc)
               else
##					  puts "   You gave me #{cls}."
                 others.push(sc)
            end		
            }	   
         if !folds.empty?
#				puts "   all folds #{folds.length}"
            folds.each { |sc| millEdges(aMill, [sc], material_thickness) }
         end
         if !centers.empty?
#				puts "   all CenterLines #{centers.length}"
            centers.each { |sc| millEdges(aMill, [sc], material_thickness) }
##				millEdges(aMill, centers, material_thickness)
         end
         if !others.empty?
#				puts "   all others #{others.length}"
            millEdges(aMill, others, material_thickness)
         end
      end	
   else  ## if not multi, just cut em
      millEdges(aMill, loopNode.sorted_cuts, material_thickness)
   end

#      end

      # finally we can walk the loop and make it's cuts
      edges = []
      reverse = false
      pe = nil
      if !loopNode.loop.nil?
        loopNode.loop.edgeuses.each{ |eu|
          pe = PhlatCut.from_edge(eu.edge)
          if (pe) && (!pe.processed)
            if (!Sketchup.active_model.get_attribute(Dict_name, Dict_overhead_gantry, Default_overhead_gantry))
                reverse = reverse || (pe.kind_of?(PhlatScript::InsideCut)) || eu.reversed?
            else
                reverse = reverse || (pe.kind_of?(PhlatScript::OutsideCut)) || eu.reversed?
            end
            edges.push(pe)
            pe.processed = true
          end
        }
        loopNode.loop_start.downto(0) { |x|
          edges.push(edges.shift) if x > 0
        }
        edges.reverse! if reverse
      end
      edges.compact!
      millEdges(aMill, edges, material_thickness, reverse)
    end

    def GcodeUtil.millEdges(aMill, edges, material_thickness, reverse=false)
      if (edges) && (!edges.empty?)
        begin
          mirror = P.get_safe_reflection_translation()
          trans = P.get_safe_origin_translation()
          trans = trans * mirror if Reflection_output

          aMill.retract()

          save_point = nil
          cut_depth = 0
          max_depth = 0
          pass = 0
          pass_depth = 0
        if @optimize
#---------------------swarfer
          if (@g_save_point != nil)
            #puts "last point  #{@g_save_point}"
            #swarfer: find closest point that is not a tabcut and re-order edges to start there
            cnt = edges.size;
            idx = 0
            mindist = 100000
            idxsave = -1
            edges.each do | phlatcut |
               if phlatcut.kind_of?( PhlatScript::CenterLineCut)
                  #find which end is closest
                  #puts "centerline #{phlatcut}"
               end
#               puts "edge #{phlatcut}"
               phlatcut.cut_points(reverse) {    |cp, cut_factor|
                  if (!phlatcut.kind_of? PhlatScript::TabCut) && (!phlatcut.kind_of? PhlatScript::PocketCut)
#                     puts "   cutpoint #{cp} #{cut_factor}"  
                     # transform the point if a transformation is provided
                     point = (trans ? (cp.transform(trans)) : cp)
                     dist = point.distance(@g_save_point)
                     if dist < mindist
                        @whichend = idxsave == idx
                        mindist = dist
                        idxsave = idx
                        #                    puts "  saved #{idx} at #{dist} distance #{point} #{@whichend}"
                     end
                     break  #only look at the first cut point
                  else
                     break
                  end #if not tabcut
                  } #cut_points
               idx += 1
            end # edges.each
         #puts "reStart from #{idxsave} of #{cnt}"
         #puts "reverse #{reverse}"
            prev = (idxsave - 1 + cnt) % cnt
            nxt = (idxsave + 1 + cnt) % cnt
              #puts edges[prev] , edges[idxsave] , edges[nxt]

            if (edges[idxsave].kind_of? PhlatScript::PlungeCut)
              idxsave = 0  # ignore plunge cuts
              changed = true
            else
              changed = false
              if (edges[idxsave].kind_of? PhlatScript::CenterLineCut)
                #puts "ignoring centerlinecut"
                changed = true
                idxsave = 0
              end
#              puts "ignoring tab cuts for the moment, just use the nearest point"

#              if (edges[idxsave].kind_of? PhlatScript::InsideCut)
#                if (!@whichend )
#                  idxsave = (idxsave - 1 + cnt) % cnt
#                  puts "   idxsave moved -1 to #{idxsave} whichend false"
#                  changed = true
#                end
#              end

              if (edges[idxsave].kind_of? PhlatScript::OutsideCut) && (reverse) && (@whichend)
                  idxsave = (idxsave + 1 + cnt) % cnt
#                  puts "   idxsave moved +1 to #{idxsave} whichend true reverse=true"
                  changed = true
              end

#idxsave 2 reverse=false whichend=true kind_of=Insidecut   +1
              if (edges[idxsave].kind_of? PhlatScript::InsideCut) && (!reverse) && (@whichend)
                  idxsave = (idxsave + 1 + cnt) % cnt
#                  puts "   idxsave moved +1 to #{idxsave} whichend true reverse=false"
                  changed = true
              end


#              if (edges[prev].kind_of? PhlatScript::TabCut) &&
#                 (edges[idxsave].kind_of? PhlatScript::OutsideCut) &&
#                 (edges[nxt].kind_of? PhlatScript::OutsideCut)
#                idxsave = (idxsave + 1 + cnt) % cnt
#                puts "   idxsave moved +1 to #{idxsave} away from outside tab TOO"
#                changed = true
#              end

 #             if (edges[prev].kind_of? PhlatScript::TabCut) &&
 #                (edges[idxsave].kind_of? PhlatScript::InsideCut) &&
 #                (edges[nxt].kind_of? PhlatScript::InsideCut)
 #               idxsave = (idxsave + 1 + cnt) % cnt
 #               #puts "   idxsave moved to #{idxsave} away from inside tab"
 #               changed = true
 #             end

#              if (edges[prev].kind_of? PhlatScript::InsideCut) &&
#                 (edges[idxsave].kind_of? PhlatScript::InsideCut) &&
#                 (edges[nxt].kind_of? PhlatScript::TabCut)
#                idxsave = (idxsave - 1 + cnt) % cnt
#                #puts "   idxsave moved to #{idxsave} away from inside tab"
#                changed = true
#              end

 #             if (edges[prev].kind_of? PhlatScript::OutsideCut) &&
 #                (edges[idxsave].kind_of? PhlatScript::OutsideCut) &&
 #                (edges[nxt].kind_of? PhlatScript::TabCut)
 #               idxsave = (idxsave - 1 + cnt) % cnt
 #               puts "   idxsave moved -1 to #{idxsave} away from outside tab OOT"
 #               changed = true
 #             end

#              if (edges[prev].kind_of? PhlatScript::OutsideCut) &&
#                 (edges[idxsave].kind_of? PhlatScript::OutsideCut) &&
#                 (edges[nxt].kind_of? PhlatScript::OutsideCut)
#                idxsave = (idxsave + 1 + cnt) % cnt
#                puts "   idxsave moved +1 #{idxsave} OOO"
#                changed = true
#              end

#              if (edges[prev].kind_of? PhlatScript::InsideCut) &&
#                 (edges[idxsave].kind_of? PhlatScript::InsideCut) &&
#                 (edges[nxt].kind_of? PhlatScript::InsideCut)
#                idxsave = (idxsave - 1 + cnt) % cnt
#                puts "   idxsave moved -1 #{idxsave} III"
#                changed = true
#              end

#              if !changed
#                 if reverse
#                   idxsave = (idxsave + 1 + cnt) % cnt
#                   puts "   idxsave moved to #{idxsave} reverse=true"
#                 else
#                   idxsave = (idxsave + 1 + cnt) % cnt
#                   puts "   idxsave moved to #{idxsave} reverse=false"
#                 end
#              end
            end # else is not plungecut
            
            ctype = "other"
            if (edges[idxsave].kind_of? PhlatScript::InsideCut)
               ctype = "Insidecut"
            end
            if (edges[idxsave].kind_of? PhlatScript::OutsideCut)
               ctype = "Outsidecut"
            end
            
#puts "  idxsave #{idxsave} reverse=#{reverse} whichend=#{@whichend} kind_of=#{ctype}"
#idxsave = 0
            if (idxsave != 0)
              newedges = []
              done = false
              idx = idxsave # start here
              puts "moving #{ctype} to idxsave #{idxsave} #{ctype}"
              while (!done)
                newedges.push(edges[idx])
#               puts "   pushed #{idx} #{edges[idx]}"
                idx += 1
                if idx == cnt
                  idx = 0
                end
                if idx == idxsave
                  done = true
                end
              end #while
              edges = newedges
            end

          end # if g_save_point
#---------------------
        end # optimize

         points = edges.size
         pass_depth = 0
         prog = PhProgressBar.new(edges.length)
         prog.symbols("e","E")
			printPass = true
         begin # multipass
            pass += 1
				aMill.cncPrint("(Pass: #{pass.to_s})\n") if (PhlatScript.useMultipass? && printPass)
            ecnt = 0
            edges.each do | phlatcut |
               ecnt = ecnt + 1
               prog.update(ecnt)
               cut_started = false
               point = nil
               cut_depth = 0
               
               phlatcut.cut_points(reverse) { |cp, cut_factor|
                  prev_pass_depth = pass_depth
                  cut_depth = -1.0 * material_thickness * (cut_factor.to_f/100).to_f
                  # store the max depth encountered to determine if another pass is needed
                  max_depth = [max_depth, cut_depth].min

                  if PhlatScript.useMultipass?
                     cut_depth = [cut_depth, (-1.0 * PhlatScript.multipassDepth * pass)].max
                     pass_depth = [pass_depth, cut_depth].min
                  end

                  # transform the point if a transformation is provided
                  point = (trans ? (cp.transform(trans)) : cp)

                  # retract if this cut does not start where the last one ended
                  if ((save_point.nil?) || (save_point.x != point.x) || (save_point.y != point.y) || (save_point.z != cut_depth))
                     if (!cut_started)
                        if PhlatScript.useMultipass?  # multipass retract avoid by Yoram
                        # If it's peck drilling we want it to retract after each plunge to clear the tool
                           if (phlatcut.kind_of? PlungeCut)
                              if pass == 1
                                 #puts "plunge multi #{phlatcut}"
                                 aMill.retract()
                                 aMill.move(point.x, point.y)
                                 #aMill.plung(cut_depth)
                                 if phlatcut.diameter > 0
                                    diam = phlatcut.diameter
                                 else
                                    diam = @current_bit_diameter
                                 end
                                 c_depth = -1.0 * material_thickness * (cut_factor.to_f/100).to_f
#                                puts "c_depth #{c_depth.to_mm} #{diam.to_mm}"
                                 aMill.plungebore(point.x, point.y, c_depth, diam)
											printPass = false  # prevent print pass comments because holes are self contained and empty passes freak users out
                              end
                           else
                              if  ((phlatcut.kind_of? CenterLineCut) || (phlatcut.kind_of? PocketCut))
                                 # for these cuts we must retract else we get collisions with existing material
                                 # this results from commenting the code in lines 203-205 to stop using 'oldmethod'
                                 # for pockets.
                                 if (points > 1) #if cutting more than 1 edge at a time, must retract
                                    aMill.retract()
                                 else
                       #            if multipass and 1 edge and not finished , then partly retract
#                                    puts "#{PhlatScript.useMultipass?} #{points==1} #{pass>1} #{(pass_depth-max_depth).abs >= 0} #{phlatcut.kind_of?(CenterLineCut)}" 
                                    if PhlatScript.useMultipass? && (points == 1) && 
                                          (pass > 1) && ((pass_depth-max_depth).abs >= 0.0) && (phlatcut.kind_of?(CenterLineCut) ) 
#                                       puts "   part retract"
#                                       aMill.cncPrint("(PARTIAL RETRACT)\n")
                                       aMill.retract(prev_pass_depth+ 0.5.mm )
                                       ccmd = "G00" #must be 00 to prevent aMill.move overriding the cmd because zo is not safe height
                                    end
                                 end
                                 if ccmd
#                                    aMill.cncPrint("(RAPID #{ccmd})\n")
                                    aMill.move(point.x, point.y, prev_pass_depth + 0.5.mm , PhlatScript.feedRate, ccmd)
                                    ccmd = nil
                                 else
                                    aMill.move(point.x, point.y) 
                                 end   
                                 aMill.plung(cut_depth, PhlatScript.plungeRate)
                              else
                                 # If it's not a peck drilling we don't need retract
                                 aMill.move(point.x, point.y)
                                 aMill.plung(cut_depth, PhlatScript.plungeRate)
                              end
                           end # if else plungcut
                        else #NOT multipass
                           aMill.retract()
                           aMill.move(point.x, point.y)
                           if (phlatcut.kind_of? PlungeCut)
                              #puts "plunge #{phlatcut}"
                              #puts "   plunge dia #{phlatcut.diameter}"
                              if phlatcut.diameter > 0
                                 diam = phlatcut.diameter
                                 aMill.plungebore(point.x, point.y, cut_depth, diam)
                              else
                                 aMill.plung(cut_depth, PhlatScript.plungeRate)
                              end
                           else
                              aMill.plung(cut_depth, PhlatScript.plungeRate)
                           end # if plungecut
                        end # if else multipass
                     else #cut in progress
                        if ((phlatcut.kind_of? PhlatArc) && (phlatcut.is_arc?) && ((save_point.nil?) || (save_point.x != point.x) || (save_point.y != point.y)))
                           g3 = reverse ? !phlatcut.g3? : phlatcut.g3?
                           # if speed limit is enabled for arc vtabs set the feed rate to the plunge rate here
                           if (phlatcut.kind_of? PhlatScript::TabCut) && (phlatcut.vtab?) && (Use_vtab_speed_limit)
                              aMill.arcmove(point.x, point.y, phlatcut.radius, g3, cut_depth, PhlatScript.plungeRate)
                           else
                              aMill.arcmove(point.x, point.y, phlatcut.radius, g3, cut_depth)
                           end
                        else
                           aMill.move(point.x, point.y, cut_depth)
                        end
                     end # if !cutstarted
                  end # if point != savepoint
                  cut_started = true
                  save_point = (point.nil?) ? nil : Geom::Point3d.new(point.x, point.y, cut_depth)
                  }
               end # edges.each
# new condition, detect 'close enough' to max_depth instead of equality, 
# for some multipass settings this would result in an extra pass with the same depth
         end until ((!PhlatScript.useMultipass?) || ( (pass_depth-max_depth).abs < 0.0001) )
         if save_point != nil
            @g_save_point = save_point   # for optimizer
         end
         rescue Exception => e
            UI.messagebox "Exception in millEdges "+$! + e.backtrace.to_s
         end
      end
   end

    def GcodeUtil.enter_file_dialog(model=Sketchup.active_model)
      output_directory_name = PhlatScript.cncFileDir
      output_filename = PhlatScript.cncFileName
      status = false
      result = UI.savepanel(PhlatScript.getString("Save CNC File"), output_directory_name, output_filename)
      if(result != nil)
        # if there isn't a file extension set it to the default
        result += Default_file_ext if (File.extname(result).empty?)
        PhlatScript.cncFile = result
        PhlatScript.checkParens(result, "Output File")
        status = true
      end
      status
    end

    def GcodeUtil.points_in_points(test_pts, bounding_pts)
      fits = true
      test_pts.each { |pt|
        next if !fits
        fits = Geom.point_in_polygon_2D(pt, bounding_pts, false)
      }
      return fits
    end

  end

end
# $Id$
